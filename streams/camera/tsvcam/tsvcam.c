// SPDX-License-Identifier: MIT
/*
 * tsvcam: S5KC505A raw capture through CAMSS RDI0 and a small CPU ISP.
 * See tsvcam.h for the interface.
 */
#define _GNU_SOURCE
#include "tsvcam.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/media.h>
#include <linux/v4l2-subdev.h>
#include <linux/videodev2.h>
#include <math.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <turbojpeg.h>
#include <unistd.h>

#ifndef SW_CAMERA_LENS_COVER
#define SW_CAMERA_LENS_COVER 0x09
#endif

#define SENSOR_PREFIX	"s5kc505a"
#define PIXEL_RATE	190000000.0	/* fixed for every mode (see the driver) */
#define LINE_LENGTH_FULL 3112		/* modes 0 and 1 */
#define LINE_LENGTH_CROP 2760		/* mode 2 */
#define BLACK_LEVEL	64		/* 10-bit */
#define WHITE_LEVEL	1023
#define EXPOSURE_MARGIN	8		/* lines, exposure <= frame length - 8 */
#define AGAIN_MIN	32		/* code, 32 = 1x */
#define AGAIN_MAX	511
#define DGAIN_MAX	4.0f		/* applied in the LUT once analogue gain is at its top */
#define LIN_MAX		4095		/* linear working range after black level */
#define MAX_BUFFERS	6

struct mode_desc {
	int w, h, hts, vts;
};

static const struct mode_desc modes[] = {
	[TSVCAM_MODE_FULL]   = { 2608, 1960, LINE_LENGTH_FULL, 2030 },
	[TSVCAM_MODE_BINNED] = { 1304,  980, LINE_LENGTH_FULL, 2030 },
	[TSVCAM_MODE_CROP]   = { 1936, 1096, LINE_LENGTH_CROP, 1166 },
};

struct buffer {
	void *mem;
	size_t len;
};

struct tsvcam {
	struct tsvcam_config cfg;
	const struct mode_desc *mode;
	int media_fd, sensor_fd, video_fd, input_fd;
	enum v4l2_buf_type buf_type;
	int stride;			/* raw bytes per line */
	struct buffer bufs[MAX_BUFFERS];
	int nbufs;
	int streaming;
	uint32_t last_seq;
	int have_last;

	/* sensor state */
	double line_us;
	int vts_min, vts_max, vts;	/* frame length in lines */
	int exp_lines, again;		/* as programmed */
	float dgain;
	uint32_t settle_seq;		/* first frame that reflects the last change */
	int converged;
	float last_mean;

	/* white balance (gains relative to green) */
	float wb_r, wb_b;
	int awb_init;

	/* tables */
	uint16_t lut[3][1024];		/* raw10 -> linear 0..LIN_MAX, per channel, black/WB/dgain */
	uint8_t gamma[LIN_MAX + 1];
	int ccm[3][3];			/* Q10 */
	int lut_dirty;

	/* output */
	uint8_t *rgb;
	size_t rgb_size;
	int out_w, out_h;
	uint16_t *rows;			/* unpacked raw rows: 3 x (w + 2) */
	uint8_t *line;			/* one unrotated RGB row */
	uint8_t *strip;			/* STRIP_ROWS unrotated rows for 90/270 */
	int strip_w, strip_n, strip_y0;
	uint8_t *rawcopy;		/* private copy of the frame being converted */
	uint16_t *lin;			/* planar linear R, G, B and matrix output: 6 x strip_w */
	tjhandle tj;
	uint8_t *jpeg;
	size_t jpeg_cap;
};

/* Exposure state carried between handles in one process, so a second open
 * starts where the last one ended instead of from the defaults. */
static double carry_exposure_us = 33000.0;
static float carry_gain = 2.0f;
static float carry_wb_r = 1.6f, carry_wb_b = 1.5f;
static int carry_valid;

static void logf_(const struct tsvcam *cam, const char *fmt, ...)
{
	va_list ap;

	if (cam && !cam->cfg.verbose)
		return;
	va_start(ap, fmt);
	fputs("tsvcam: ", stderr);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static double cpu_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

const char *tsvcam_strerror(int err)
{
	switch (err) {
	case TSVCAM_OK: return "ok";
	case TSVCAM_ECOVER: return "lens cover closed";
	case TSVCAM_ENODEV: return "camera not found";
	case TSVCAM_EBUSY: return "camera in use";
	case TSVCAM_EIO: return "camera I/O error";
	case TSVCAM_ETIMEDOUT: return "no frame in time";
	case TSVCAM_ENOMEM: return "out of memory";
	case TSVCAM_EINVAL: return "invalid argument";
	case TSVCAM_EJPEG: return "JPEG encoding failed";
	}
	return "unknown error";
}

void tsvcam_config_default(struct tsvcam_config *cfg, int mode, int output)
{
	memset(cfg, 0, sizeof(*cfg));
	cfg->mode = mode;
	cfg->output = output;
	cfg->rotate = -1;
	cfg->min_fps = 10;
	cfg->max_exposure_us = 66000;
	cfg->flicker_hz = 50;
	cfg->saturation = 1.35f;
	cfg->ae_target = 0.16f;
	cfg->buffers = 3;
	cfg->verbose = getenv("TSVCAM_VERBOSE") != NULL;
}

/* ---- lens cover ---------------------------------------------------------- */

static int open_cover_input(void)
{
	char path[64], name[64];
	int i, fd;

	for (i = 0; i < 32; i++) {
		snprintf(path, sizeof(path), "/dev/input/event%d", i);
		fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
		if (fd < 0)
			continue;
		unsigned long sw[(SW_MAX + 1 + 8 * sizeof(long) - 1) / (8 * sizeof(long))] = { 0 };
		if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) > 0 && !strcmp(name, "gpio-keys") &&
		    ioctl(fd, EVIOCGBIT(EV_SW, sizeof(sw)), sw) >= 0 &&
		    (sw[SW_CAMERA_LENS_COVER / (8 * sizeof(long))] >> (SW_CAMERA_LENS_COVER % (8 * sizeof(long)))) & 1)
			return fd;
		close(fd);
	}
	return -1;
}

static int cover_closed_fd(int fd)
{
	unsigned long sw[(SW_MAX + 1 + 8 * sizeof(long) - 1) / (8 * sizeof(long))] = { 0 };

	if (fd < 0)
		return TSVCAM_ENODEV;
	if (ioctl(fd, EVIOCGSW(sizeof(sw)), sw) < 0)
		return TSVCAM_EIO;
	return (sw[SW_CAMERA_LENS_COVER / (8 * sizeof(long))] >> (SW_CAMERA_LENS_COVER % (8 * sizeof(long)))) & 1;
}

int tsvcam_cover_closed(void)
{
	int fd = open_cover_input(), r;

	/* No switch to read means we cannot prove the cover is open: refuse. */
	if (fd < 0)
		return TSVCAM_ENODEV;
	r = cover_closed_fd(fd);
	close(fd);
	return r;
}

/* ---- media graph --------------------------------------------------------- */

static int find_entity(int mfd, const char *prefix, struct media_entity_desc *out)
{
	struct media_entity_desc e;

	memset(&e, 0, sizeof(e));
	e.id = MEDIA_ENT_ID_FLAG_NEXT;
	while (!xioctl(mfd, MEDIA_IOC_ENUM_ENTITIES, &e)) {
		if (!strncmp(e.name, prefix, strlen(prefix))) {
			*out = e;
			return 0;
		}
		e.id |= MEDIA_ENT_ID_FLAG_NEXT;
	}
	return -1;
}

static int open_devnode(const struct media_entity_desc *e, int flags)
{
	char path[96], line[128], dev[80] = "";
	FILE *f;

	snprintf(path, sizeof(path), "/sys/dev/char/%u:%u/uevent", e->dev.major, e->dev.minor);
	f = fopen(path, "re");
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f))
		if (!strncmp(line, "DEVNAME=", 8)) {
			line[strcspn(line, "\n")] = 0;
			snprintf(dev, sizeof(dev), "/dev/%s", line + 8);
		}
	fclose(f);
	return dev[0] ? open(dev, flags | O_CLOEXEC) : -1;
}

/* Disable every enabled, mutable link (media-ctl -r). */
static void reset_links(int mfd)
{
	struct media_entity_desc e;

	memset(&e, 0, sizeof(e));
	e.id = MEDIA_ENT_ID_FLAG_NEXT;
	while (!xioctl(mfd, MEDIA_IOC_ENUM_ENTITIES, &e)) {
		struct media_links_enum le;
		struct media_link_desc *links = calloc(e.links ? e.links : 1, sizeof(*links));
		struct media_pad_desc *pads = calloc(e.pads ? e.pads : 1, sizeof(*pads));

		memset(&le, 0, sizeof(le));
		le.entity = e.id;
		le.links = links;
		le.pads = pads;
		if (links && pads && !xioctl(mfd, MEDIA_IOC_ENUM_LINKS, &le)) {
			for (unsigned i = 0; i < e.links; i++) {
				struct media_link_desc l = links[i];
				if (l.source.entity != e.id || !(l.flags & MEDIA_LNK_FL_ENABLED) ||
				    (l.flags & MEDIA_LNK_FL_IMMUTABLE))
					continue;
				l.flags &= ~MEDIA_LNK_FL_ENABLED;
				xioctl(mfd, MEDIA_IOC_SETUP_LINK, &l);
			}
		}
		free(links);
		free(pads);
		e.id |= MEDIA_ENT_ID_FLAG_NEXT;
	}
}

static int media_link(int mfd, const char *src, int spad, const char *sink, int dpad)
{
	struct media_entity_desc a, b;
	struct media_link_desc l;

	if (find_entity(mfd, src, &a) || find_entity(mfd, sink, &b))
		return -1;
	memset(&l, 0, sizeof(l));
	l.source.entity = a.id;
	l.source.index = spad;
	l.sink.entity = b.id;
	l.sink.index = dpad;
	l.flags = MEDIA_LNK_FL_ENABLED;
	if (xioctl(mfd, MEDIA_IOC_SETUP_LINK, &l) && errno != EINVAL)
		return -1;	/* EINVAL: immutable link, already on */
	return 0;
}

static int set_pad_fmt(int mfd, const char *ent, int pad, int w, int h)
{
	struct media_entity_desc e;
	struct v4l2_subdev_format f;
	int fd, r;

	if (find_entity(mfd, ent, &e))
		return -1;
	fd = open_devnode(&e, O_RDWR);
	if (fd < 0)
		return -1;
	memset(&f, 0, sizeof(f));
	f.which = V4L2_SUBDEV_FORMAT_ACTIVE;
	f.pad = pad;
	f.format.width = w;
	f.format.height = h;
	f.format.code = MEDIA_BUS_FMT_SGRBG10_1X10;
	f.format.field = V4L2_FIELD_NONE;
	f.format.colorspace = V4L2_COLORSPACE_RAW;
	r = xioctl(fd, VIDIOC_SUBDEV_S_FMT, &f);
	close(fd);
	if (r || f.format.width != (unsigned)w || f.format.height != (unsigned)h ||
	    f.format.code != MEDIA_BUS_FMT_SGRBG10_1X10) {
		fprintf(stderr, "tsvcam: %s pad %d: format %ux%u code 0x%x (%s)\n", ent, pad,
			f.format.width, f.format.height, f.format.code, r ? strerror(errno) : "adjusted");
		return -1;
	}
	return 0;
}

/*
 * Kernels without "s5kc505a: accept the read-only timing controls" fail a
 * mode change with EINVAL while the sensor is still runtime active (1 s
 * autosuspend after the last stream). Wait for it to suspend first, but
 * only when the mode is about to change.
 */
static void wait_sensor_idle(int mfd, const char *name, int w, int h)
{
	struct media_entity_desc e;
	struct v4l2_subdev_format f;
	char path[128], st[32];
	int fd;

	if (find_entity(mfd, name, &e))
		return;
	fd = open_devnode(&e, O_RDWR);
	if (fd < 0)
		return;
	memset(&f, 0, sizeof(f));
	f.which = V4L2_SUBDEV_FORMAT_ACTIVE;
	if (!xioctl(fd, VIDIOC_SUBDEV_G_FMT, &f) && f.format.width == (unsigned)w &&
	    f.format.height == (unsigned)h) {
		close(fd);
		return;
	}
	close(fd);
	snprintf(path, sizeof(path), "/sys/dev/char/%u:%u/device/power/runtime_status",
		 e.dev.major, e.dev.minor);
	for (int i = 0; i < 40; i++) {
		FILE *fp = fopen(path, "re");
		if (!fp || !fgets(st, sizeof(st), fp) || strncmp(st, "active", 6)) {
			if (fp)
				fclose(fp);
			return;
		}
		fclose(fp);
		usleep(50000);
	}
}

/* ---- sensor controls ----------------------------------------------------- */

static int ctrl_set(int fd, uint32_t id, int val)
{
	struct v4l2_control c = { .id = id, .value = val };

	return xioctl(fd, VIDIOC_S_CTRL, &c);
}

static int ctrl_get(int fd, uint32_t id, int *val)
{
	struct v4l2_control c = { .id = id };

	if (xioctl(fd, VIDIOC_G_CTRL, &c))
		return -1;
	*val = c.value;
	return 0;
}

/* Program frame length, exposure and gain. Order matters: the driver limits
 * exposure to the current frame length, so lengthen first / shorten last. */
static int apply_sensor(struct tsvcam *cam, int vts, int exp_lines, int again)
{
	int ret = 0;

	if (vts > cam->vts)
		ret |= ctrl_set(cam->sensor_fd, V4L2_CID_VBLANK, vts - cam->mode->h);
	if (exp_lines != cam->exp_lines)
		ret |= ctrl_set(cam->sensor_fd, V4L2_CID_EXPOSURE, exp_lines);
	if (vts < cam->vts)
		ret |= ctrl_set(cam->sensor_fd, V4L2_CID_VBLANK, vts - cam->mode->h);
	if (again != cam->again)
		ret |= ctrl_set(cam->sensor_fd, V4L2_CID_ANALOGUE_GAIN, again);
	if (ret)
		fprintf(stderr, "tsvcam: control write failed: %s\n", strerror(errno));
	cam->vts = vts;
	cam->exp_lines = exp_lines;
	cam->again = again;
	return ret ? TSVCAM_EIO : 0;
}

/* Split a total exposure (us x gain) into lines, frame length and gains. */
static void plan_exposure(struct tsvcam *cam, double total, int *vts, int *lines,
			  int *again, float *dgain)
{
	double t_max = cam->cfg.max_exposure_us, t, g, period;
	double frame_cap_us = 1e6 / (cam->cfg.min_fps > 0 ? cam->cfg.min_fps : 1);

	if (t_max > frame_cap_us - EXPOSURE_MARGIN * cam->line_us)
		t_max = frame_cap_us - EXPOSURE_MARGIN * cam->line_us;
	t = total < t_max ? total : t_max;
	period = cam->cfg.flicker_hz > 0 ? 1e6 / (2.0 * cam->cfg.flicker_hz) : 0;
	if (period > 0 && t >= period)
		t = floor(t / period) * period;
	if (t < cam->line_us)
		t = cam->line_us;
	*lines = (int)lround(t / cam->line_us);
	if (*lines < 1)
		*lines = 1;
	t = *lines * cam->line_us;
	g = total / t;
	if (g < 1.0)
		g = 1.0;
	*again = (int)lround(g * AGAIN_MIN);
	if (*again > AGAIN_MAX)
		*again = AGAIN_MAX;
	if (*again < AGAIN_MIN)
		*again = AGAIN_MIN;
	*dgain = (float)(g / (*again / (double)AGAIN_MIN));
	if (*dgain < 1.0f)
		*dgain = 1.0f;
	if (*dgain > DGAIN_MAX)
		*dgain = DGAIN_MAX;
	*vts = *lines + EXPOSURE_MARGIN;
	if (*vts < cam->vts_min)
		*vts = cam->vts_min;
	if (*vts > cam->vts_max)
		*vts = cam->vts_max;
}

static double current_total(const struct tsvcam *cam)
{
	return cam->exp_lines * cam->line_us * (cam->again / (double)AGAIN_MIN) * cam->dgain;
}

/* ---- tables -------------------------------------------------------------- */

static void build_tables(struct tsvcam *cam)
{
	float gains[3] = { cam->wb_r, 1.0f, cam->wb_b };
	float s = cam->cfg.saturation;
	/* Rec.601 luma weights for the saturation matrix */
	const float lw[3] = { 0.299f, 0.587f, 0.114f };

	for (int c = 0; c < 3; c++) {
		double k = (double)LIN_MAX / (WHITE_LEVEL - BLACK_LEVEL) * gains[c] * cam->dgain;
		for (int v = 0; v < 1024; v++) {
			double x = (v - BLACK_LEVEL) * k;
			cam->lut[c][v] = x <= 0 ? 0 : x >= LIN_MAX ? LIN_MAX : (uint16_t)(x + 0.5);
		}
	}
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++)
			cam->ccm[i][j] = (int)lroundf(((1.0f - s) * lw[j] + (i == j ? s : 0.0f)) * 1024.0f);
	cam->lut_dirty = 0;
}

static void build_gamma(struct tsvcam *cam)
{
	for (int i = 0; i <= LIN_MAX; i++) {
		double x = i / (double)LIN_MAX, y;
		y = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055;
		cam->gamma[i] = (uint8_t)lround(y * 255.0);
	}
}

/* ---- statistics, AE and AWB ---------------------------------------------- */

static inline int raw10_at(const uint8_t *row, int x)
{
	const uint8_t *p = row + (x >> 2) * 5;
	int s = (x & 3) * 2;

	return (p[x & 3] << 2) | ((p[4] >> s) & 3);
}

struct stats {
	double sum_g, sum_r_awb, sum_g_awb, sum_b_awb;
	int n, n_awb, n_sat;
	int hist[64];
	float grid[TSVCAM_GRID_H][TSVCAM_GRID_W];
	int grid_n[TSVCAM_GRID_H][TSVCAM_GRID_W];
};

static void gather_stats(const struct tsvcam *cam, const uint8_t *raw, struct stats *st)
{
	int w = cam->mode->w, h = cam->mode->h;
	/* about 6000 quads whatever the mode */
	int step = 2 * (int)ceil(sqrt((w / 2.0) * (h / 2.0) / 6000.0));
	const double range = WHITE_LEVEL - BLACK_LEVEL;

	memset(st, 0, sizeof(*st));
	for (int y = step / 2 & ~1; y + 1 < h; y += step) {
		const uint8_t *r0 = raw + (size_t)y * cam->stride, *r1 = r0 + cam->stride;
		for (int x = step / 2 & ~1; x + 1 < w; x += step) {
			/* GRBG: (0,0) Gr, (1,0) R, (0,1) B, (1,1) Gb */
			int gr = raw10_at(r0, x), r = raw10_at(r0, x + 1);
			int b = raw10_at(r1, x), gb = raw10_at(r1, x + 1);
			double G = ((gr + gb) / 2.0 - BLACK_LEVEL) / range;
			double R = (r - BLACK_LEVEL) / range, B = (b - BLACK_LEVEL) / range;
			int hb;

			if (G < 0) G = 0;
			if (R < 0) R = 0;
			if (B < 0) B = 0;
			st->sum_g += G;
			st->n++;
			{
				int gx = x * TSVCAM_GRID_W / w, gy = y * TSVCAM_GRID_H / h;
				st->grid[gy][gx] += (float)G;
				st->grid_n[gy][gx]++;
			}
			hb = (int)(G * 64);
			st->hist[hb > 63 ? 63 : hb]++;
			if (G > 0.92 || R > 0.92 || B > 0.92) {
				st->n_sat++;
				continue;
			}
			if (G < 0.02)
				continue;
			st->sum_r_awb += R;
			st->sum_g_awb += G;
			st->sum_b_awb += B;
			st->n_awb++;
		}
	}
}

static void update_awb(struct tsvcam *cam, const struct stats *st)
{
	float r, b, a;

	if (st->n_awb < st->n / 20 || st->sum_r_awb <= 0 || st->sum_b_awb <= 0)
		return;
	r = (float)(st->sum_g_awb / st->sum_r_awb);
	b = (float)(st->sum_g_awb / st->sum_b_awb);
	r = r < 0.6f ? 0.6f : r > 4.0f ? 4.0f : r;
	b = b < 0.6f ? 0.6f : b > 4.0f ? 4.0f : b;
	a = cam->awb_init ? 0.35f : 1.0f;
	cam->wb_r += a * (r - cam->wb_r);
	cam->wb_b += a * (b - cam->wb_b);
	cam->awb_init = 1;
	cam->lut_dirty = 1;
}

/* Returns 1 if the sensor was reprogrammed. */
static int update_ae(struct tsvcam *cam, const struct stats *st, uint32_t seq)
{
	double mean = st->n ? st->sum_g / st->n : 0, ratio, total;
	int vts, lines, again;
	float dgain;
	int top = 0;

	cam->last_mean = (float)mean;
	if (seq < cam->settle_seq)
		return 0;
	/*
	 * Two goals: the mean green at the target, and the brightest 2 % of the
	 * samples below clipping. When they disagree (a lamp or window in view)
	 * the highlights win, but the mean is not pushed below 0.6 x target;
	 * min(mean ratio, max(highlight ratio, 0.6 x mean ratio)) has a fixed
	 * point there, so AE settles instead of hunting.
	 */
	(void)top;
	if (mean < 1e-4)
		mean = 1e-4;
	double r_mean = cam->cfg.ae_target / mean, r_hi, p98 = 1.0;
	for (int i = 63, acc = 0; i >= 0; i--) {
		acc += st->hist[i];
		if (acc > st->n / 50) {
			p98 = (i + 1) / 64.0;
			break;
		}
	}
	r_hi = 0.85 / p98;
	ratio = r_mean;
	if (r_hi < ratio)
		ratio = r_hi > 0.6 * r_mean ? r_hi : 0.6 * r_mean;
	if (fabs(log(ratio)) < 0.12) {
		cam->converged = 1;
		return 0;
	}
	cam->converged = 0;
	if (ratio > 8) ratio = 8;
	if (ratio < 0.125) ratio = 0.125;
	ratio = pow(ratio, 0.85);
	total = current_total(cam) * ratio;
	plan_exposure(cam, total, &vts, &lines, &again, &dgain);
	if (lines == cam->exp_lines && again == cam->again && vts == cam->vts &&
	    fabsf(dgain - cam->dgain) < 0.01f) {
		cam->converged = 1;	/* at a limit */
		return 0;
	}
	apply_sensor(cam, vts, lines, again);
	if (fabsf(dgain - cam->dgain) >= 0.01f) {
		cam->dgain = dgain;
		cam->lut_dirty = 1;
	}
	/* the sensor takes new integration settings two frames later */
	cam->settle_seq = seq + 3;
	return 1;
}

/* ---- conversion ---------------------------------------------------------- */

#define STRIP_ROWS 16

/*
 * Finish one row held as planar linear R, G, B (0..LIN_MAX) in cam->lin:
 * saturation matrix and clamp (a loop the compiler vectorises), then the
 * sRGB gamma table into interleaved RGB.
 */
static void finish_row(const struct tsvcam *cam, uint8_t *restrict d, int n)
{
	const int m00 = cam->ccm[0][0], m01 = cam->ccm[0][1], m02 = cam->ccm[0][2];
	const int m10 = cam->ccm[1][0], m11 = cam->ccm[1][1], m12 = cam->ccm[1][2];
	const int m20 = cam->ccm[2][0], m21 = cam->ccm[2][1], m22 = cam->ccm[2][2];
	const int lw = cam->strip_w;
	const uint16_t *restrict R = cam->lin, *restrict G = R + lw, *restrict B = G + lw;
	uint16_t *restrict oR = cam->lin + 3 * lw, *restrict oG = oR + lw, *restrict oB = oG + lw;
	const uint8_t *restrict gm = cam->gamma;

	for (int i = 0; i < n; i++) {
		int r = R[i], g = G[i], b = B[i];
		int x = (m00 * r + m01 * g + m02 * b) >> 10;
		int y = (m10 * r + m11 * g + m12 * b) >> 10;
		int z = (m20 * r + m21 * g + m22 * b) >> 10;
		oR[i] = (uint16_t)(x < 0 ? 0 : x > LIN_MAX ? LIN_MAX : x);
		oG[i] = (uint16_t)(y < 0 ? 0 : y > LIN_MAX ? LIN_MAX : y);
		oB[i] = (uint16_t)(z < 0 ? 0 : z > LIN_MAX ? LIN_MAX : z);
	}
	for (int i = 0; i < n; i++, d += 3) {
		d[0] = gm[oR[i]];
		d[1] = gm[oG[i]];
		d[2] = gm[oB[i]];
	}
}

/* Write the buffered strip of unrotated rows y0..y0+n-1 (each w pixels, of
 * an image w x h) into the rotated output. */
static void flush_strip(struct tsvcam *cam, int w, int h)
{
	int n = cam->strip_n, y0 = cam->strip_y0;
	const uint8_t *s = cam->strip;
	size_t ostride = (size_t)cam->out_w * 3;

	if (!n)
		return;
	if (cam->cfg.rotate == 90) {		/* (x, y) -> (h-1-y, x) */
		for (int x = 0; x < w; x++) {
			uint8_t *d = cam->rgb + (size_t)x * ostride + (size_t)(h - y0 - n) * 3;
			for (int k = n - 1; k >= 0; k--, d += 3)
				memcpy(d, s + ((size_t)k * w + x) * 3, 3);
		}
	} else {				/* 270: (x, y) -> (y, w-1-x) */
		for (int x = 0; x < w; x++) {
			uint8_t *d = cam->rgb + (size_t)(w - 1 - x) * ostride + (size_t)y0 * 3;
			for (int k = 0; k < n; k++, d += 3)
				memcpy(d, s + ((size_t)k * w + x) * 3, 3);
		}
	}
	cam->strip_n = 0;
}

/* Where to put unrotated row y (w pixels); call row_done() after filling it. */
static uint8_t *row_dst(struct tsvcam *cam, int y, int h)
{
	switch (cam->cfg.rotate) {
	case 0:
		return cam->rgb + (size_t)y * cam->out_w * 3;
	case 180:
		return cam->line;
	default:
		if (!cam->strip_n)
			cam->strip_y0 = y;
		return cam->strip + (size_t)cam->strip_n * cam->strip_w * 3;
	}
}

static void row_done(struct tsvcam *cam, int y, int w, int h)
{
	if (cam->cfg.rotate == 180) {
		uint8_t *d = cam->rgb + (size_t)(h - 1 - y) * cam->out_w * 3 + (size_t)(w - 1) * 3;
		const uint8_t *s = cam->line;
		for (int x = 0; x < w; x++, s += 3, d -= 3)
			memcpy(d, s, 3);
	} else if (cam->cfg.rotate) {
		if (++cam->strip_n == STRIP_ROWS || y == h - 1)
			flush_strip(cam, w, h);
	}
}

/* Unpack one RAW10 row into dst[0..w-1] and mirror one sample on each side
 * (dst[-1] = dst[1], dst[w] = dst[w-2]) so the demosaic needs no edge cases. */
static void unpack_row(const uint8_t *src, uint16_t *dst, int w)
{
	for (int x = 0; x + 3 < w; x += 4, src += 5) {
		uint8_t lo = src[4];
		dst[x] = (src[0] << 2) | (lo & 3);
		dst[x + 1] = (src[1] << 2) | ((lo >> 2) & 3);
		dst[x + 2] = (src[2] << 2) | ((lo >> 4) & 3);
		dst[x + 3] = (src[3] << 2) | (lo >> 6);
	}
	dst[-1] = dst[1];
	dst[w] = dst[w - 2];
}

/* One RGB pixel per GRBG quad. */
static void convert_half(struct tsvcam *cam, const uint8_t *raw)
{
	int w = cam->mode->w, h = cam->mode->h, ow = w / 2, oh = h / 2, lw = cam->strip_w;
	uint16_t *r0 = cam->rows + 1, *r1 = cam->rows + 1 + (w + 2);
	const uint16_t *lr = cam->lut[0], *lg = cam->lut[1], *lb = cam->lut[2];
	uint16_t *R = cam->lin, *G = R + lw, *B = G + lw;

	for (int y = 0; y < oh; y++) {
		unpack_row(raw + (size_t)(2 * y) * cam->stride, r0, w);
		unpack_row(raw + (size_t)(2 * y + 1) * cam->stride, r1, w);
		for (int x = 0; x < ow; x++) {
			R[x] = lr[r0[2 * x + 1]];
			G[x] = (lg[r0[2 * x]] + lg[r1[2 * x + 1]]) >> 1;
			B[x] = lb[r1[2 * x]];
		}
		finish_row(cam, row_dst(cam, y, oh), ow);
		row_done(cam, y, ow, oh);
	}
}

/* Bilinear demosaic of GRBG; edges mirror. */
static void convert_full(struct tsvcam *cam, const uint8_t *raw)
{
	int w = cam->mode->w, h = cam->mode->h, lw = cam->strip_w;
	size_t rs = w + 2;
	uint16_t *rb[3] = { cam->rows + 1, cam->rows + 1 + rs, cam->rows + 1 + 2 * rs };
	const uint16_t *LR = cam->lut[0], *LG = cam->lut[1], *LB = cam->lut[2];
	uint16_t *R = cam->lin, *G = R + lw, *B = G + lw;

	unpack_row(raw + (size_t)1 * cam->stride, rb[0], w);	/* row -1 mirrors row 1 */
	unpack_row(raw, rb[1], w);
	unpack_row(raw + (size_t)1 * cam->stride, rb[2], w);
	for (int y = 0; y < h; y++) {
		const uint16_t *up = rb[y % 3], *c = rb[(y + 1) % 3], *dn = rb[(y + 2) % 3];

		if (!(y & 1)) {
			for (int x = 0; x < w; x += 2) {
				/* Gr at x: R left/right, B up/down */
				R[x] = LR[(c[x - 1] + c[x + 1] + 1) >> 1];
				G[x] = LG[c[x]];
				B[x] = LB[(up[x] + dn[x] + 1) >> 1];
				/* R at x+1 */
				R[x + 1] = LR[c[x + 1]];
				G[x + 1] = LG[(c[x] + c[x + 2] + up[x + 1] + dn[x + 1] + 2) >> 2];
				B[x + 1] = LB[(up[x] + up[x + 2] + dn[x] + dn[x + 2] + 2) >> 2];
			}
		} else {
			for (int x = 0; x < w; x += 2) {
				/* B at x */
				R[x] = LR[(up[x - 1] + up[x + 1] + dn[x - 1] + dn[x + 1] + 2) >> 2];
				G[x] = LG[(c[x - 1] + c[x + 1] + up[x] + dn[x] + 2) >> 2];
				B[x] = LB[c[x]];
				/* Gb at x+1: B left/right, R up/down */
				R[x + 1] = LR[(up[x + 1] + dn[x + 1] + 1) >> 1];
				G[x + 1] = LG[c[x + 1]];
				B[x + 1] = LB[(c[x] + c[x + 2] + 1) >> 1];
			}
		}
		finish_row(cam, row_dst(cam, y, h), w);
		row_done(cam, y, w, h);
		/* the row that was "up" becomes row y+2 (mirrored past the bottom) */
		int ny = y + 2 < h ? y + 2 : h - 2;
		unpack_row(raw + (size_t)ny * cam->stride, rb[y % 3], w);
	}
}

/* ---- capture ------------------------------------------------------------- */

static int setup_pipeline(struct tsvcam *cam)
{
	char sensor_name[64];
	struct media_entity_desc e;
	int w = cam->mode->w, h = cam->mode->h, i;

	for (i = 0; i < 8; i++) {
		char path[32];
		struct media_device_info info;

		snprintf(path, sizeof(path), "/dev/media%d", i);
		cam->media_fd = open(path, O_RDWR | O_CLOEXEC);
		if (cam->media_fd < 0)
			continue;
		if (!xioctl(cam->media_fd, MEDIA_IOC_DEVICE_INFO, &info) &&
		    !strcmp(info.driver, "qcom-camss"))
			break;
		close(cam->media_fd);
		cam->media_fd = -1;
	}
	if (cam->media_fd < 0 || find_entity(cam->media_fd, SENSOR_PREFIX, &e))
		return TSVCAM_ENODEV;
	snprintf(sensor_name, sizeof(sensor_name), "%s", e.name);
	cam->sensor_fd = open_devnode(&e, O_RDWR);
	if (cam->sensor_fd < 0)
		return TSVCAM_ENODEV;

	reset_links(cam->media_fd);
	wait_sensor_idle(cam->media_fd, sensor_name, w, h);
	if (media_link(cam->media_fd, sensor_name, 0, "msm_csiphy0", 0) ||
	    media_link(cam->media_fd, "msm_csiphy0", 1, "msm_csid0", 0) ||
	    media_link(cam->media_fd, "msm_csid0", 1, "msm_ispif0", 0) ||
	    media_link(cam->media_fd, "msm_ispif0", 1, "msm_vfe0_rdi0", 0)) {
		fprintf(stderr, "tsvcam: link setup failed: %s\n", strerror(errno));
		return errno == EBUSY ? TSVCAM_EBUSY : TSVCAM_EIO;
	}
	if (set_pad_fmt(cam->media_fd, sensor_name, 0, w, h) ||
	    set_pad_fmt(cam->media_fd, "msm_csiphy0", 0, w, h) ||
	    set_pad_fmt(cam->media_fd, "msm_csid0", 0, w, h) ||
	    set_pad_fmt(cam->media_fd, "msm_ispif0", 0, w, h) ||
	    set_pad_fmt(cam->media_fd, "msm_vfe0_rdi0", 0, w, h))
		return errno == EBUSY ? TSVCAM_EBUSY : TSVCAM_EIO;

	if (find_entity(cam->media_fd, "msm_vfe0_video0", &e))
		return TSVCAM_ENODEV;
	cam->video_fd = open_devnode(&e, O_RDWR | O_NONBLOCK);
	if (cam->video_fd < 0)
		return errno == EBUSY ? TSVCAM_EBUSY : TSVCAM_ENODEV;
	return 0;
}

static int setup_buffers(struct tsvcam *cam)
{
	struct v4l2_capability cap;
	struct v4l2_format f;
	struct v4l2_requestbuffers rb;
	int mp;

	if (xioctl(cam->video_fd, VIDIOC_QUERYCAP, &cap))
		return TSVCAM_EIO;
	mp = !!((cap.capabilities & V4L2_CAP_DEVICE_CAPS ? cap.device_caps : cap.capabilities) &
		V4L2_CAP_VIDEO_CAPTURE_MPLANE);
	cam->buf_type = mp ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE : V4L2_BUF_TYPE_VIDEO_CAPTURE;

	memset(&f, 0, sizeof(f));
	f.type = cam->buf_type;
	if (mp) {
		f.fmt.pix_mp.width = cam->mode->w;
		f.fmt.pix_mp.height = cam->mode->h;
		f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_SGRBG10P;
		f.fmt.pix_mp.field = V4L2_FIELD_NONE;
		f.fmt.pix_mp.num_planes = 1;
	} else {
		f.fmt.pix.width = cam->mode->w;
		f.fmt.pix.height = cam->mode->h;
		f.fmt.pix.pixelformat = V4L2_PIX_FMT_SGRBG10P;
		f.fmt.pix.field = V4L2_FIELD_NONE;
	}
	if (xioctl(cam->video_fd, VIDIOC_S_FMT, &f))
		return errno == EBUSY ? TSVCAM_EBUSY : TSVCAM_EIO;
	cam->stride = mp ? (int)f.fmt.pix_mp.plane_fmt[0].bytesperline : (int)f.fmt.pix.bytesperline;
	if (cam->stride < cam->mode->w * 5 / 4)
		return TSVCAM_EIO;

	memset(&rb, 0, sizeof(rb));
	rb.count = cam->cfg.buffers;
	rb.type = cam->buf_type;
	rb.memory = V4L2_MEMORY_MMAP;
	if (xioctl(cam->video_fd, VIDIOC_REQBUFS, &rb))
		return errno == EBUSY ? TSVCAM_EBUSY : TSVCAM_EIO;
	cam->nbufs = rb.count > MAX_BUFFERS ? MAX_BUFFERS : rb.count;
	for (int i = 0; i < cam->nbufs; i++) {
		struct v4l2_buffer b;
		struct v4l2_plane pl[1];
		off_t off;

		memset(&b, 0, sizeof(b));
		memset(pl, 0, sizeof(pl));
		b.type = cam->buf_type;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (mp) {
			b.m.planes = pl;
			b.length = 1;
		}
		if (xioctl(cam->video_fd, VIDIOC_QUERYBUF, &b))
			return TSVCAM_EIO;
		cam->bufs[i].len = mp ? pl[0].length : b.length;
		off = mp ? pl[0].m.mem_offset : b.m.offset;
		cam->bufs[i].mem = mmap(NULL, cam->bufs[i].len, PROT_READ | PROT_WRITE, MAP_SHARED,
					cam->video_fd, off);
		if (cam->bufs[i].mem == MAP_FAILED) {
			cam->bufs[i].mem = NULL;
			return TSVCAM_ENOMEM;
		}
		if (xioctl(cam->video_fd, VIDIOC_QBUF, &b))
			return TSVCAM_EIO;
	}
	return 0;
}

static void stop_stream(struct tsvcam *cam)
{
	if (cam->streaming) {
		enum v4l2_buf_type t = cam->buf_type;
		xioctl(cam->video_fd, VIDIOC_STREAMOFF, &t);
		cam->streaming = 0;
	}
}

void tsvcam_close(tsvcam *cam)
{
	if (!cam)
		return;
	if (cam->exp_lines > 0) {
		carry_exposure_us = cam->exp_lines * cam->line_us;
		carry_gain = cam->again / (float)AGAIN_MIN * cam->dgain;
		carry_wb_r = cam->wb_r;
		carry_wb_b = cam->wb_b;
		carry_valid = 1;
	}
	stop_stream(cam);
	for (int i = 0; i < cam->nbufs; i++)
		if (cam->bufs[i].mem)
			munmap(cam->bufs[i].mem, cam->bufs[i].len);
	if (cam->video_fd >= 0) {
		struct v4l2_requestbuffers rb = { .count = 0, .type = cam->buf_type,
						   .memory = V4L2_MEMORY_MMAP };
		xioctl(cam->video_fd, VIDIOC_REQBUFS, &rb);
		close(cam->video_fd);
	}
	if (cam->sensor_fd >= 0)
		close(cam->sensor_fd);
	if (cam->media_fd >= 0)
		close(cam->media_fd);
	if (cam->input_fd >= 0)
		close(cam->input_fd);
	if (cam->tj)
		tj3Destroy(cam->tj);
	tj3Free(cam->jpeg);
	free(cam->rgb);
	free(cam->rows);
	free(cam->line);
	free(cam->strip);
	free(cam->lin);
	free(cam->rawcopy);
	free(cam);
}

tsvcam *tsvcam_open(const struct tsvcam_config *cfg, int *err)
{
	struct tsvcam *cam;
	int r, rot = 0;
	enum v4l2_buf_type t;
	int dummy;

	if (cfg->mode < 0 || cfg->mode > TSVCAM_MODE_CROP || cfg->output < 0 || cfg->output > 1) {
		*err = TSVCAM_EINVAL;
		return NULL;
	}
	cam = calloc(1, sizeof(*cam));
	if (!cam) {
		*err = TSVCAM_ENOMEM;
		return NULL;
	}
	cam->cfg = *cfg;
	if (cam->cfg.buffers < 2 || cam->cfg.buffers > MAX_BUFFERS)
		cam->cfg.buffers = 3;
	cam->mode = &modes[cfg->mode];
	cam->media_fd = cam->sensor_fd = cam->video_fd = -1;

	cam->input_fd = open_cover_input();
	r = cover_closed_fd(cam->input_fd);
	if (r != 0) {
		*err = r > 0 ? TSVCAM_ECOVER : r;
		goto fail;
	}

	r = setup_pipeline(cam);
	if (r)
		goto fail_r;
	if (cam->cfg.rotate < 0)
		cam->cfg.rotate = ctrl_get(cam->sensor_fd, V4L2_CID_CAMERA_SENSOR_ROTATION, &rot) ? 0 :
				  (360 - rot) % 360;	/* V4L2 gives the counter-clockwise correction */
	if (cam->cfg.rotate % 90) {
		r = TSVCAM_EINVAL;
		goto fail_r;
	}
	cam->cfg.rotate %= 360;

	cam->line_us = cam->mode->hts / PIXEL_RATE * 1e6;
	cam->vts_min = cam->mode->vts;
	cam->vts_max = (int)(1e6 / (cam->cfg.min_fps > 0 ? cam->cfg.min_fps : 1) / cam->line_us);
	if (cam->vts_max < cam->vts_min)
		cam->vts_max = cam->vts_min;
	if (cam->vts_max > 0xffff)
		cam->vts_max = 0xffff;
	cam->vts = cam->vts_min;	/* reset by the format change */
	if (!ctrl_get(cam->sensor_fd, V4L2_CID_VBLANK, &dummy))
		cam->vts = dummy + cam->mode->h;
	ctrl_get(cam->sensor_fd, V4L2_CID_EXPOSURE, &cam->exp_lines);
	ctrl_get(cam->sensor_fd, V4L2_CID_ANALOGUE_GAIN, &cam->again);
	ctrl_set(cam->sensor_fd, V4L2_CID_TEST_PATTERN, 0);
	cam->dgain = 1.0f;
	cam->wb_r = carry_wb_r;
	cam->wb_b = carry_wb_b;
	cam->awb_init = carry_valid;
	{
		int vts, lines, again;
		float dg;
		plan_exposure(cam, carry_exposure_us * carry_gain, &vts, &lines, &again, &dg);
		apply_sensor(cam, vts, lines, again);
		cam->dgain = dg;
	}
	build_gamma(cam);
	build_tables(cam);

	r = setup_buffers(cam);
	if (r)
		goto fail_r;

	cam->out_w = cfg->output == TSVCAM_OUT_HALF ? cam->mode->w / 2 : cam->mode->w;
	cam->out_h = cfg->output == TSVCAM_OUT_HALF ? cam->mode->h / 2 : cam->mode->h;
	cam->rgb_size = (size_t)cam->out_w * cam->out_h * 3;
	if (cam->cfg.rotate == 90 || cam->cfg.rotate == 270) {
		int tmp = cam->out_w;
		cam->out_w = cam->out_h;
		cam->out_h = tmp;
	}
	cam->rgb = malloc(cam->rgb_size);
	cam->rows = malloc(sizeof(uint16_t) * 3 * (cam->mode->w + 2));
	cam->strip_w = cfg->output == TSVCAM_OUT_HALF ? cam->mode->w / 2 : cam->mode->w;
	cam->line = malloc((size_t)cam->strip_w * 3);
	cam->strip = malloc((size_t)cam->strip_w * 3 * STRIP_ROWS);
	cam->lin = malloc(sizeof(uint16_t) * 6 * cam->strip_w);
	cam->rawcopy = malloc((size_t)cam->stride * cam->mode->h);
	if (!cam->rgb || !cam->rows || !cam->line || !cam->strip || !cam->lin || !cam->rawcopy) {
		r = TSVCAM_ENOMEM;
		goto fail_r;
	}

	t = cam->buf_type;
	if (xioctl(cam->video_fd, VIDIOC_STREAMON, &t)) {
		fprintf(stderr, "tsvcam: STREAMON: %s\n", strerror(errno));
		r = errno == EBUSY ? TSVCAM_EBUSY : TSVCAM_EIO;
		goto fail_r;
	}
	cam->streaming = 1;
	cam->settle_seq = 3;
	logf_(cam, "mode %dx%d stride %d, out %dx%d rot %d, %d buffers, line %.2f us, frame %d..%d lines\n",
	      cam->mode->w, cam->mode->h, cam->stride, cam->out_w, cam->out_h, cam->cfg.rotate,
	      cam->nbufs, cam->line_us, cam->vts_min, cam->vts_max);
	*err = 0;
	return cam;

fail_r:
	*err = r;
fail:
	tsvcam_close(cam);
	return NULL;
}

/* Dequeue the newest ready buffer (waiting up to timeout_ms for one). The
 * caller re-queues it. Older ready buffers are re-queued here. */
static int dequeue_newest(struct tsvcam *cam, struct v4l2_buffer *out, struct v4l2_plane *opl,
			  int timeout_ms)
{
	int got = 0;
	double deadline = now_ms() + timeout_ms;

	for (;;) {
		struct v4l2_buffer b;
		struct v4l2_plane pl[1];

		memset(&b, 0, sizeof(b));
		memset(pl, 0, sizeof(pl));
		b.type = cam->buf_type;
		b.memory = V4L2_MEMORY_MMAP;
		if (cam->buf_type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
			b.m.planes = pl;
			b.length = 1;
		}
		if (!xioctl(cam->video_fd, VIDIOC_DQBUF, &b)) {
			if (b.flags & V4L2_BUF_FLAG_ERROR) {
				xioctl(cam->video_fd, VIDIOC_QBUF, &b);
				continue;
			}
			if (got) {
				struct v4l2_buffer old = *out;
				if (old.type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
					old.m.planes = opl;
				xioctl(cam->video_fd, VIDIOC_QBUF, &old);
			}
			*out = b;
			opl[0] = pl[0];
			got = 1;
			continue;
		}
		if (errno != EAGAIN)
			return TSVCAM_EIO;
		if (got)
			return 0;
		int left = (int)(deadline - now_ms());
		if (left <= 0)
			return TSVCAM_ETIMEDOUT;
		struct pollfd p = { .fd = cam->video_fd, .events = POLLIN };
		if (poll(&p, 1, left) < 0 && errno != EINTR)
			return TSVCAM_EIO;
	}
}

static int grab(struct tsvcam *cam, struct tsvcam_frame *fr, int convert, int timeout_ms)
{
	struct v4l2_buffer b;
	struct v4l2_plane pl[1];
	struct stats st;
	const uint8_t *raw;
	int r;

	if (!cam->streaming)
		return TSVCAM_EIO;
	r = cover_closed_fd(cam->input_fd);
	if (r != 0) {
		stop_stream(cam);
		return r > 0 ? TSVCAM_ECOVER : r;
	}
	for (;;) {
		r = dequeue_newest(cam, &b, pl, timeout_ms);
		if (r)
			return r;
		if (!cam->have_last || b.sequence != cam->last_seq)
			break;
		if (b.type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
			b.m.planes = pl;
		xioctl(cam->video_fd, VIDIOC_QBUF, &b);
	}
	cam->last_seq = b.sequence;
	cam->have_last = 1;
	/*
	 * Copy the frame out and give the buffer straight back: CAMSS RDI
	 * ping-pongs between two queued buffers, and holding one for the
	 * length of a demosaic (50-200 ms) starves it and loses frames.
	 */
	double t0 = cpu_ms();
	if (convert) {
		memcpy(cam->rawcopy, cam->bufs[b.index].mem, (size_t)cam->stride * cam->mode->h);
		raw = cam->rawcopy;
	} else {
		raw = cam->bufs[b.index].mem;
	}
	if (convert) {
		struct v4l2_buffer q = b;
		if (q.type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
			q.m.planes = pl;
		if (xioctl(cam->video_fd, VIDIOC_QBUF, &q))
			return TSVCAM_EIO;
	}

	gather_stats(cam, raw, &st);
	float mean_before = st.n ? (float)(st.sum_g / st.n) : 0;
	int exp_us = (int)lround(cam->exp_lines * cam->line_us);
	float gain = cam->again / (float)AGAIN_MIN * cam->dgain;
	/* AWB only on frames that reflect the current exposure */
	if (b.sequence >= cam->settle_seq)
		update_awb(cam, &st);
	if (convert) {
		if (cam->lut_dirty)
			build_tables(cam);
		if (cam->cfg.output == TSVCAM_OUT_HALF)
			convert_half(cam, raw);
		else
			convert_full(cam, raw);
	}
	update_ae(cam, &st, b.sequence);
	double t1 = cpu_ms();

	if (fr) {
		memset(fr, 0, sizeof(*fr));
		fr->rgb = cam->rgb;
		fr->width = cam->out_w;
		fr->height = cam->out_h;
		fr->stride = cam->out_w * 3;
		fr->sequence = b.sequence;
		fr->timestamp_ns = (uint64_t)b.timestamp.tv_sec * 1000000000ull + b.timestamp.tv_usec * 1000ull;
		fr->exposure_us = exp_us;
		fr->gain = gain;
		fr->wb_r = cam->wb_r;
		fr->wb_b = cam->wb_b;
		fr->mean = mean_before;
		fr->converged = cam->converged;
		fr->process_ms = (float)(t1 - t0);
		for (int gy = 0; gy < TSVCAM_GRID_H; gy++)
			for (int gx = 0; gx < TSVCAM_GRID_W; gx++) {
				float v = st.grid_n[gy][gx] ? st.grid[gy][gx] / st.grid_n[gy][gx] : 0;
				v = v * 255.0f + 0.5f;
				fr->luma_grid[gy * TSVCAM_GRID_W + gx] = (uint8_t)(v > 255 ? 255 : v);
			}
	}
	logf_(cam, "seq %u exp %d us gain %.2f (a%d d%.2f) vts %d mean %.3f sat %d/%d wb %.2f/%.2f%s %.1f ms\n",
	      b.sequence, exp_us, gain, cam->again, cam->dgain, cam->vts, mean_before, st.hist[63], st.n,
	      cam->wb_r, cam->wb_b, cam->converged ? " ok" : "", t1 - t0);

	if (!convert) {
		if (b.type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
			b.m.planes = pl;
		if (xioctl(cam->video_fd, VIDIOC_QBUF, &b))
			return TSVCAM_EIO;
	}
	return 0;
}

int tsvcam_next_frame(tsvcam *cam, struct tsvcam_frame *frame, int timeout_ms)
{
	return grab(cam, frame, 1, timeout_ms);
}

int tsvcam_settle(tsvcam *cam, int timeout_ms)
{
	double end = now_ms() + timeout_ms;
	int n = 0, ok = 0, r;

	while (now_ms() < end) {
		r = grab(cam, NULL, 0, 1000);
		if (r)
			return r;
		n++;
		/* two converged, settled frames in a row */
		if (cam->converged && cam->last_seq >= cam->settle_seq) {
			if (++ok >= 2)
				break;
		} else {
			ok = 0;
		}
	}
	return n;
}

int tsvcam_jpeg(tsvcam *cam, const struct tsvcam_frame *fr, int quality, const uint8_t **jpeg,
		size_t *len)
{
	size_t sz;

	if (!cam->tj) {
		cam->tj = tj3Init(TJINIT_COMPRESS);
		if (!cam->tj)
			return TSVCAM_EJPEG;
	}
	tj3Set(cam->tj, TJPARAM_QUALITY, quality < 1 ? 1 : quality > 100 ? 100 : quality);
	tj3Set(cam->tj, TJPARAM_SUBSAMP, TJSAMP_420);
	tj3Set(cam->tj, TJPARAM_FASTDCT, 1);
	tj3Set(cam->tj, TJPARAM_NOREALLOC, 1);
	sz = tj3JPEGBufSize(fr->width, fr->height, TJSAMP_420);
	if (sz > cam->jpeg_cap) {
		tj3Free(cam->jpeg);
		cam->jpeg = tj3Alloc(sz);
		cam->jpeg_cap = cam->jpeg ? sz : 0;
		if (!cam->jpeg)
			return TSVCAM_ENOMEM;
	}
	*len = cam->jpeg_cap;
	if (tj3Compress8(cam->tj, fr->rgb, fr->width, fr->stride, fr->height, TJPF_RGB, &cam->jpeg, len)) {
		fprintf(stderr, "tsvcam: %s\n", tj3GetErrorStr(cam->tj));
		return TSVCAM_EJPEG;
	}
	*jpeg = cam->jpeg;
	return 0;
}

int tsvcam_nv12(const struct tsvcam_frame *fr, uint8_t *dst)
{
	int w = fr->width, h = fr->height;
	uint8_t *uv = dst + (size_t)w * h;

	if ((w | h) & 1)
		return TSVCAM_EINVAL;
	for (int y = 0; y < h; y += 2) {
		const uint8_t *p0 = fr->rgb + (size_t)y * fr->stride, *p1 = p0 + fr->stride;
		uint8_t *y0 = dst + (size_t)y * w, *y1 = y0 + w;
		for (int x = 0; x < w; x += 2) {
			int rs = 0, gs = 0, bs = 0;
			for (int k = 0; k < 2; k++) {
				const uint8_t *a = p0 + (x + k) * 3, *c = p1 + (x + k) * 3;
				y0[x + k] = (uint8_t)(((66 * a[0] + 129 * a[1] + 25 * a[2] + 128) >> 8) + 16);
				y1[x + k] = (uint8_t)(((66 * c[0] + 129 * c[1] + 25 * c[2] + 128) >> 8) + 16);
				rs += a[0] + c[0];
				gs += a[1] + c[1];
				bs += a[2] + c[2];
			}
			rs = (rs + 2) >> 2; gs = (gs + 2) >> 2; bs = (bs + 2) >> 2;
			uv[(y / 2) * w + x] = (uint8_t)(((-38 * rs - 74 * gs + 112 * bs + 128) >> 8) + 128);
			uv[(y / 2) * w + x + 1] = (uint8_t)(((112 * rs - 94 * gs - 18 * bs + 128) >> 8) + 128);
		}
	}
	return 0;
}

int tsvcam_photo(int half, int quality, int settle_ms, uint8_t **jpeg, size_t *len,
		 struct tsvcam_frame *info)
{
	struct tsvcam_config cfg;
	struct tsvcam_frame fr;
	const uint8_t *j;
	tsvcam *cam;
	int err, r;

	tsvcam_config_default(&cfg, TSVCAM_MODE_FULL, half ? TSVCAM_OUT_HALF : TSVCAM_OUT_FULL);
	cfg.max_exposure_us = 100000;	/* a still can take a longer exposure than the stream */
	cfg.min_fps = 8;
	cam = tsvcam_open(&cfg, &err);
	if (!cam)
		return err;
	r = tsvcam_settle(cam, settle_ms);
	if (r >= 0)
		r = tsvcam_next_frame(cam, &fr, 1000);
	if (!r)
		r = tsvcam_jpeg(cam, &fr, quality, &j, len);
	if (!r) {
		*jpeg = malloc(*len);
		if (*jpeg)
			memcpy(*jpeg, j, *len);
		else
			r = TSVCAM_ENOMEM;
	}
	if (!r && info) {
		*info = fr;
		info->rgb = NULL;
	}
	tsvcam_close(cam);
	return r;
}

/* Conversion and JPEG cost on a synthetic frame, without the camera. */
int tsvcam_bench(int mode, int output, int rotate, int iters, double *convert_ms, double *jpeg_ms)
{
	struct tsvcam_config cfg;
	struct tsvcam *cam;
	struct tsvcam_frame fr;
	const uint8_t *j;
	uint8_t *raw;
	size_t len;
	int w, h, r = 0;

	if (mode < 0 || mode > TSVCAM_MODE_CROP || iters < 1)
		return TSVCAM_EINVAL;
	tsvcam_config_default(&cfg, mode, output);
	cam = calloc(1, sizeof(*cam));
	if (!cam)
		return TSVCAM_ENOMEM;
	cam->cfg = cfg;
	cam->cfg.rotate = rotate;
	cam->mode = &modes[mode];
	cam->media_fd = cam->sensor_fd = cam->video_fd = cam->input_fd = -1;
	w = cam->mode->w;
	h = cam->mode->h;
	cam->stride = (w * 5 / 4 + 15) & ~15;
	cam->wb_r = 1.6f;
	cam->wb_b = 2.1f;
	cam->dgain = 1.0f;
	build_gamma(cam);
	build_tables(cam);
	cam->strip_w = output == TSVCAM_OUT_HALF ? w / 2 : w;
	cam->out_w = cam->strip_w;
	cam->out_h = output == TSVCAM_OUT_HALF ? h / 2 : h;
	if (rotate == 90 || rotate == 270) {
		int t = cam->out_w;
		cam->out_w = cam->out_h;
		cam->out_h = t;
	}
	raw = malloc((size_t)cam->stride * h);
	cam->rgb = malloc((size_t)cam->out_w * cam->out_h * 3);
	cam->rows = malloc(sizeof(uint16_t) * 3 * (w + 2));
	cam->line = malloc((size_t)cam->strip_w * 3);
	cam->strip = malloc((size_t)cam->strip_w * 3 * STRIP_ROWS);
	cam->lin = malloc(sizeof(uint16_t) * 6 * cam->strip_w);
	if (!raw || !cam->rgb || !cam->rows || !cam->line || !cam->strip || !cam->lin) {
		free(raw);
		tsvcam_close(cam);
		return TSVCAM_ENOMEM;
	}
	/* a smooth gradient with some texture, so JPEG has work to do */
	for (int y = 0; y < h; y++)
		for (int x = 0; x < cam->stride; x++)
			raw[(size_t)y * cam->stride + x] = (uint8_t)(64 + ((x * 3 + y * 2) & 127) + ((x * y) & 15));
	double c = 0, jt = 0;
	for (int i = 0; i < iters && !r; i++) {
		double t0 = cpu_ms();
		if (output == TSVCAM_OUT_HALF)
			convert_half(cam, raw);
		else
			convert_full(cam, raw);
		double t1 = cpu_ms();
		fr.rgb = cam->rgb;
		fr.width = cam->out_w;
		fr.height = cam->out_h;
		fr.stride = cam->out_w * 3;
		r = tsvcam_jpeg(cam, &fr, 85, &j, &len);
		c += t1 - t0;
		jt += cpu_ms() - t1;
	}
	*convert_ms = c / iters;
	*jpeg_ms = jt / iters;
	free(raw);
	tsvcam_close(cam);
	return r;
}
