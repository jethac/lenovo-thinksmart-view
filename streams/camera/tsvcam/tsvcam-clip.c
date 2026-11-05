// SPDX-License-Identifier: MIT
/*
 * tsvcam clips: frames chosen by change (tsvsel), encoded to H.264 on the
 * Venus hardware encoder through V4L2 mem2mem, muxed into an in-memory MP4
 * (mp4mux). No ffmpeg, no files.
 */
#define _GNU_SOURCE
#include "tsvcam.h"
#include "mp4mux.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/select.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define ENC_OUT_BUFS 4		/* raw frames in flight */
#define ENC_CAP_BUFS 4		/* bitstream buffers */

struct mbuf {
	void *mem;
	size_t len;
	int queued;
};

struct tsvcam_venc {
	int fd;
	int width, height, fps;
	int bpl, scanlines;		/* raw frame layout the driver wants */
	size_t frame_size;
	struct mbuf out[ENC_OUT_BUFS], cap[ENC_CAP_BUFS];
	int nout, ncap;
	struct mp4mux *mux;
	size_t bytes;
	int frames_in, frames_out;
	int streaming, eos, stopping;
	int err;
	unsigned flags;
};

static int trace_on = -1;

static void trace(const char *fmt, ...)
{
	va_list ap;

	if (trace_on < 0)
		trace_on = getenv("TSVCAM_TRACE") != NULL;
	if (!trace_on)
		return;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fflush(stderr);
}

static const char *qname(uint32_t type)
{
	return type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE ? "OUT" :
	       type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ? "CAP" : "?";
}

/* print the call and its arguments, flushed, before making it */
static void trace_call(unsigned long req, const void *arg)
{
	if (trace_on < 0)
		trace_on = getenv("TSVCAM_TRACE") != NULL;
	if (!trace_on)
		return;
	switch (req) {
	case VIDIOC_S_FMT: case VIDIOC_G_FMT: {
		const struct v4l2_format *f = arg;
		trace("venc: %s %s %ux%u %.4s sizeimage %u bpl %u\n", req == VIDIOC_S_FMT ? "S_FMT" : "G_FMT",
		      qname(f->type), f->fmt.pix_mp.width, f->fmt.pix_mp.height,
		      (const char *)&f->fmt.pix_mp.pixelformat, f->fmt.pix_mp.plane_fmt[0].sizeimage,
		      f->fmt.pix_mp.plane_fmt[0].bytesperline);
		break; }
	case VIDIOC_REQBUFS: {
		const struct v4l2_requestbuffers *r = arg;
		trace("venc: REQBUFS %s count %u\n", qname(r->type), r->count);
		break; }
	case VIDIOC_QUERYBUF: {
		const struct v4l2_buffer *b = arg;
		trace("venc: QUERYBUF %s index %u\n", qname(b->type), b->index);
		break; }
	case VIDIOC_QBUF: case VIDIOC_DQBUF: {
		const struct v4l2_buffer *b = arg;
		trace("venc: %s %s index %u bytesused %u length %u flags 0x%x\n",
		      req == VIDIOC_QBUF ? "QBUF" : "DQBUF", qname(b->type), b->index,
		      b->m.planes ? b->m.planes[0].bytesused : 0, b->m.planes ? b->m.planes[0].length : 0,
		      b->flags);
		break; }
	case VIDIOC_STREAMON: case VIDIOC_STREAMOFF:
		trace("venc: %s %s\n", req == VIDIOC_STREAMON ? "STREAMON" : "STREAMOFF",
		      qname(*(const uint32_t *)arg));
		break;
	case VIDIOC_S_CTRL: {
		const struct v4l2_control *c = arg;
		trace("venc: S_CTRL 0x%x = %d\n", c->id, c->value);
		break; }
	case VIDIOC_S_PARM:
		trace("venc: S_PARM %s\n", qname(((const struct v4l2_streamparm *)arg)->type));
		break;
	case VIDIOC_ENCODER_CMD:
		trace("venc: ENCODER_CMD %u\n", ((const struct v4l2_encoder_cmd *)arg)->cmd);
		break;
	default:
		trace("venc: ioctl 0x%lx\n", req);
	}
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	trace_call(req, arg);
	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	if (r && trace_on > 0 && !(req == VIDIOC_DQBUF && errno == EAGAIN))
		trace("venc:   -> error %s\n", strerror(errno));
	else if (!r && req == VIDIOC_DQBUF) {
		const struct v4l2_buffer *b = arg;
		trace("venc:   -> %s index %u bytesused %u flags 0x%x\n", qname(b->type), b->index,
		      b->m.planes ? b->m.planes[0].bytesused : 0, b->flags);
	}
	return r;
}

static int open_encoder(int nonblock)
{
	DIR *d = opendir("/sys/class/video4linux");
	struct dirent *e;
	int fd = -1;

	if (!d)
		return -1;
	while (fd < 0 && (e = readdir(d))) {
		char p[300], name[64] = "";
		FILE *f;

		if (strncmp(e->d_name, "video", 5))
			continue;
		snprintf(p, sizeof(p), "/sys/class/video4linux/%s/name", e->d_name);
		f = fopen(p, "re");
		if (!f)
			continue;
		if (fgets(name, sizeof(name), f) && !strncmp(name, "qcom-venus-encoder", 18)) {
			snprintf(p, sizeof(p), "/dev/%s", e->d_name);
			trace("venc: open %s%s\n", p, nonblock ? " O_NONBLOCK" : "");
			fd = open(p, O_RDWR | O_CLOEXEC | (nonblock ? O_NONBLOCK : 0));
		}
		fclose(f);
	}
	closedir(d);
	return fd;
}

static void set_ctrl(int fd, uint32_t id, int val, const char *what)
{
	struct v4l2_control c = { .id = id, .value = val };

	if (xioctl(fd, VIDIOC_S_CTRL, &c))
		fprintf(stderr, "tsvcam: encoder %s: %s\n", what, strerror(errno));
}

static int set_cap_fmt(struct tsvcam_venc *e)
{
	struct v4l2_format f;

	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	f.fmt.pix_mp.width = e->width;
	f.fmt.pix_mp.height = e->height;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_H264;
	f.fmt.pix_mp.num_planes = 1;
	return xioctl(e->fd, VIDIOC_S_FMT, &f);
}

static int map_bufs(struct tsvcam_venc *e, enum v4l2_buf_type type, struct mbuf *b, int count, int *got);
static int queue_cap(struct tsvcam_venc *e, int i);

/* bitstream buffers: allocate, map and queue */
static int start_capture(struct tsvcam_venc *e)
{
	if (map_bufs(e, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, e->cap, ENC_CAP_BUFS, &e->ncap) || e->ncap < 1)
		return -1;
	for (int i = 0; i < e->ncap; i++)
		if (queue_cap(e, i))
			return -1;
	return 0;
}

/*
 * The order v4l2-ctl uses, which works: the first raw frame is queued,
 * then OUTPUT streams on, then the CAPTURE buffers are allocated and
 * queued, then CAPTURE streams on.
 */
static int start_streams(struct tsvcam_venc *e)
{
	enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;

	if (xioctl(e->fd, VIDIOC_STREAMON, &t))
		return -1;
	if (start_capture(e))
		return -1;
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (xioctl(e->fd, VIDIOC_STREAMON, &t))
		return -1;
	e->streaming = 1;
	return 0;
}

static int map_bufs(struct tsvcam_venc *e, enum v4l2_buf_type type, struct mbuf *b, int count, int *got)
{
	struct v4l2_requestbuffers rb = { .count = count, .type = type, .memory = V4L2_MEMORY_MMAP };

	if (xioctl(e->fd, VIDIOC_REQBUFS, &rb))
		return -1;
	*got = rb.count < (unsigned)count ? (int)rb.count : count;
	for (int i = 0; i < *got; i++) {
		struct v4l2_plane pl[1] = { 0 };
		struct v4l2_buffer q = { .type = type, .memory = V4L2_MEMORY_MMAP, .index = i,
					 .m.planes = pl, .length = 1 };

		if (xioctl(e->fd, VIDIOC_QUERYBUF, &q))
			return -1;
		b[i].len = pl[0].length;
		b[i].mem = mmap(NULL, b[i].len, PROT_READ | PROT_WRITE, MAP_SHARED, e->fd,
				pl[0].m.mem_offset);
		if (b[i].mem == MAP_FAILED) {
			b[i].mem = NULL;
			return -1;
		}
	}
	return 0;
}

static int queue_cap(struct tsvcam_venc *e, int i)
{
	struct v4l2_plane pl[1] = { 0 };
	struct v4l2_buffer q = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
				 .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = pl, .length = 1 };

	pl[0].length = e->cap[i].len;
	if (xioctl(e->fd, VIDIOC_QBUF, &q))
		return -1;
	e->cap[i].queued = 1;
	return 0;
}

void tsvcam_venc_close(struct tsvcam_venc *e)
{
	if (!e)
		return;
	/*
	 * No VIDIOC_STREAMOFF: STREAMOFF on OUTPUT after an encoder stop whose
	 * drain had not finished wedged the SoC (2026-11-05 traced run). Like
	 * v4l2-ctl, unmap and close; the m2m release stops CAPTURE, then OUTPUT.
	 */
	if (e->fd >= 0 && e->streaming && (e->flags & TSVCAM_VENC_EXPLICIT_STREAMOFF)) {
		enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		xioctl(e->fd, VIDIOC_STREAMOFF, &t);
		t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		xioctl(e->fd, VIDIOC_STREAMOFF, &t);
	}
	for (int i = 0; i < e->nout; i++)
		if (e->out[i].mem)
			munmap(e->out[i].mem, e->out[i].len);
	for (int i = 0; i < e->ncap; i++)
		if (e->cap[i].mem)
			munmap(e->cap[i].mem, e->cap[i].len);
	if (e->fd >= 0) {
		trace("venc: close\n");
		close(e->fd);
	}
	mp4mux_free(e->mux);
	free(e);
}

struct tsvcam_venc *tsvcam_venc_open(int width, int height, int fps, int bitrate, int gop,
				     unsigned flags, int *err)
{
	struct tsvcam_venc *e = calloc(1, sizeof(*e));
	struct v4l2_format f;
	struct v4l2_streamparm parm;
	enum v4l2_buf_type t;

	*err = TSVCAM_ENOMEM;
	if (!e)
		return NULL;
	*err = TSVCAM_EINVAL;
	if ((width | height) & 1 || width < 64 || height < 64 || fps < 1)
		goto fail;
	e->width = width;
	e->height = height;
	e->fps = fps;
	*err = TSVCAM_ENODEV;
	e->fd = open_encoder(!(flags & TSVCAM_VENC_V4L2CTL));
	if (e->fd < 0)
		goto fail;
	*err = TSVCAM_EIO;

	e->flags = flags;
	if ((flags & TSVCAM_VENC_CAPTURE_FIRST) && set_cap_fmt(e))
		goto fail;

	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	f.fmt.pix_mp.width = width;
	f.fmt.pix_mp.height = height;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
	f.fmt.pix_mp.num_planes = 1;
	if (xioctl(e->fd, VIDIOC_S_FMT, &f))
		goto fail;
	/* single-plane NV12: chroma follows bytesperline x (format height) */
	e->bpl = (int)f.fmt.pix_mp.plane_fmt[0].bytesperline;
	e->scanlines = (int)f.fmt.pix_mp.height;
	e->frame_size = f.fmt.pix_mp.plane_fmt[0].sizeimage;
	if (e->bpl < width || e->scanlines < height ||
	    e->frame_size < (size_t)e->bpl * e->scanlines * 3 / 2)
		goto fail;

	if (!(flags & TSVCAM_VENC_CAPTURE_FIRST) && set_cap_fmt(e))
		goto fail;

	if (flags & TSVCAM_VENC_FRAME_RATE) {
		memset(&parm, 0, sizeof(parm));
		parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		parm.parm.output.timeperframe.numerator = 1;
		parm.parm.output.timeperframe.denominator = fps;
		if (xioctl(e->fd, VIDIOC_S_PARM, &parm))
			fprintf(stderr, "tsvcam: encoder frame rate: %s\n", strerror(errno));
	}
	if (flags & TSVCAM_VENC_RATE_CTRLS) {
		set_ctrl(e->fd, V4L2_CID_MPEG_VIDEO_BITRATE_MODE, V4L2_MPEG_VIDEO_BITRATE_MODE_VBR,
			 "rate mode");
		set_ctrl(e->fd, V4L2_CID_MPEG_VIDEO_BITRATE, bitrate, "bitrate");
	}
	if (flags & TSVCAM_VENC_GOP_CTRL)
		set_ctrl(e->fd, V4L2_CID_MPEG_VIDEO_GOP_SIZE, gop, "GOP size");
	if (flags & TSVCAM_VENC_STREAM_CTRLS) {
		set_ctrl(e->fd, V4L2_CID_MPEG_VIDEO_B_FRAMES, 0, "B-frames");
		set_ctrl(e->fd, V4L2_CID_MPEG_VIDEO_H264_PROFILE, V4L2_MPEG_VIDEO_H264_PROFILE_MAIN,
			 "profile");
		set_ctrl(e->fd, V4L2_CID_MPEG_VIDEO_HEADER_MODE,
			 V4L2_MPEG_VIDEO_HEADER_MODE_JOINED_WITH_1ST_FRAME, "header mode");
	}

	if (map_bufs(e, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, e->out, ENC_OUT_BUFS, &e->nout) || e->nout < 1)
		goto fail;
	if (flags & TSVCAM_VENC_EARLY_START) {
		/* everything up front: the order that hung the tablet twice */
		if (start_capture(e))
			goto fail;
		t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		if (xioctl(e->fd, VIDIOC_STREAMON, &t))
			goto fail;
		t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		if (xioctl(e->fd, VIDIOC_STREAMON, &t))
			goto fail;
		e->streaming = 1;
	}
	/* otherwise both queues start with the first frame (start_streams()) */
	e->mux = mp4mux_new(width, height, fps);
	if (!e->mux) {
		*err = TSVCAM_ENOMEM;
		goto fail;
	}
	*err = 0;
	return e;
fail:
	if (*err == TSVCAM_EIO)
		fprintf(stderr, "tsvcam: encoder setup: %s\n", strerror(errno));
	tsvcam_venc_close(e);
	return NULL;
}

/* Collect finished buffers: bitstream into the muxer, raw frames back to free.
 * Waits up to timeout_ms for at least one event. Returns 1 when LAST was seen. */
static int reap(struct tsvcam_venc *e, int timeout_ms)
{
	struct pollfd p = { .fd = e->fd, .events = POLLIN | POLLOUT };
	int last = 0;

	if (timeout_ms && poll(&p, 1, timeout_ms) < 0 && errno != EINTR)
		return -1;
	for (;;) {			/* bitstream */
		struct v4l2_plane pl[1] = { 0 };
		struct v4l2_buffer q = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
					 .memory = V4L2_MEMORY_MMAP, .m.planes = pl, .length = 1 };

		if (xioctl(e->fd, VIDIOC_DQBUF, &q))
			break;
		e->cap[q.index].queued = 0;
		if (pl[0].bytesused > pl[0].data_offset && !(q.flags & V4L2_BUF_FLAG_ERROR)) {
			uint64_t pts = (uint64_t)q.timestamp.tv_sec * 1000000 + q.timestamp.tv_usec;
			size_t n = pl[0].bytesused - pl[0].data_offset;
			if (mp4mux_add(e->mux, (uint8_t *)e->cap[q.index].mem + pl[0].data_offset, n, pts) < 0)
				e->err = TSVCAM_ENOMEM;
			e->bytes += n;
			e->frames_out++;
		}
		if (e->stopping && pl[0].bytesused <= pl[0].data_offset)
			e->eos = 1;	/* the empty buffer the firmware returns after a stop */
		if (q.flags & V4L2_BUF_FLAG_LAST) {
			last = 1;
			break;
		}
		if (e->eos)		/* not queued again: the stream is over */
			break;
		if (queue_cap(e, q.index))
			e->err = TSVCAM_EIO;
	}
	for (;;) {			/* raw frames done */
		struct v4l2_plane pl[1] = { 0 };
		struct v4l2_buffer q = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
					 .memory = V4L2_MEMORY_MMAP, .m.planes = pl, .length = 1 };

		if (xioctl(e->fd, VIDIOC_DQBUF, &q))
			break;
		e->out[q.index].queued = 0;
	}
	return last;
}

/* RGB24 frame -> NV12 (BT.601 limited) in the driver's layout */
static void rgb_to_nv12(const struct tsvcam_frame *fr, uint8_t *y, int ys, uint8_t *uv, int w, int h)
{
	for (int r = 0; r < h; r += 2) {
		const uint8_t *p0 = fr->rgb + (size_t)r * fr->stride, *p1 = p0 + fr->stride;
		uint8_t *y0 = y + (size_t)r * ys, *y1 = y0 + ys, *c = uv + (size_t)(r / 2) * ys;
		for (int x = 0; x < w; x += 2) {
			int rs = 0, gs = 0, bs = 0;
			for (int k = 0; k < 2; k++) {
				const uint8_t *a = p0 + (x + k) * 3, *b = p1 + (x + k) * 3;
				y0[x + k] = (uint8_t)(((66 * a[0] + 129 * a[1] + 25 * a[2] + 128) >> 8) + 16);
				y1[x + k] = (uint8_t)(((66 * b[0] + 129 * b[1] + 25 * b[2] + 128) >> 8) + 16);
				rs += a[0] + b[0];
				gs += a[1] + b[1];
				bs += a[2] + b[2];
			}
			rs = (rs + 2) >> 2; gs = (gs + 2) >> 2; bs = (bs + 2) >> 2;
			c[x] = (uint8_t)(((-38 * rs - 74 * gs + 112 * bs + 128) >> 8) + 128);
			c[x + 1] = (uint8_t)(((112 * rs - 94 * gs - 18 * bs + 128) >> 8) + 128);
		}
	}
}

/* ---- v4l2-ctl compatible mode (TSVCAM_VENC_V4L2CTL) --------------------- */

/* v4l2-ctl's order once the first raw frame is queued: OUTPUT on, CAPTURE
 * format set again from scratch, CAPTURE buffers allocated and queued, on. */
static int compat_start(struct tsvcam_venc *e)
{
	enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	struct v4l2_requestbuffers rb = { .count = 0, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
					  .memory = V4L2_MEMORY_MMAP };
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE };

	if (xioctl(e->fd, VIDIOC_STREAMON, &t))
		return -1;
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	xioctl(e->fd, VIDIOC_STREAMOFF, &t);
	xioctl(e->fd, VIDIOC_REQBUFS, &rb);
	if (xioctl(e->fd, VIDIOC_G_FMT, &f) || xioctl(e->fd, VIDIOC_S_FMT, &f))
		return -1;
	if (start_capture(e))
		return -1;
	if (xioctl(e->fd, VIDIOC_STREAMON, &t))
		return -1;
	e->streaming = 1;
	return 0;
}

/* One blocking dequeue on whichever queue select() reports ready.
 * Returns 1 if LAST was seen, 0 otherwise, -1 on timeout or error. */
static int compat_step(struct tsvcam_venc *e, int timeout_ms)
{
	fd_set rd, wr, ex;
	struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
	int n, last = 0;

	FD_ZERO(&rd); FD_ZERO(&wr); FD_ZERO(&ex);
	FD_SET(e->fd, &rd);
	FD_SET(e->fd, &wr);
	FD_SET(e->fd, &ex);
	n = select(e->fd + 1, &rd, &wr, &ex, &tv);
	if (n <= 0)
		return -1;
	/* a blocking DQBUF on a queue with nothing in the driver would never
	 * return, so only dequeue where buffers are out */
	int caps_out = 0, outs_out = 0;
	for (int k = 0; k < e->ncap; k++)
		caps_out += e->cap[k].queued;
	for (int k = 0; k < e->nout; k++)
		outs_out += e->out[k].queued;
	if (!caps_out)
		FD_CLR(e->fd, &rd);
	if (!outs_out)
		FD_CLR(e->fd, &wr);
	if (FD_ISSET(e->fd, &rd)) {
		struct v4l2_plane pl[1] = { 0 };
		struct v4l2_buffer q = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
					 .memory = V4L2_MEMORY_MMAP, .m.planes = pl, .length = 1 };
		if (xioctl(e->fd, VIDIOC_DQBUF, &q))
			return -1;
		e->cap[q.index].queued = 0;
		if (pl[0].bytesused > pl[0].data_offset && !(q.flags & V4L2_BUF_FLAG_ERROR)) {
			uint64_t pts = (uint64_t)q.timestamp.tv_sec * 1000000 + q.timestamp.tv_usec;
			size_t len = pl[0].bytesused - pl[0].data_offset;
			if (mp4mux_add(e->mux, (uint8_t *)e->cap[q.index].mem + pl[0].data_offset, len, pts) < 0)
				e->err = TSVCAM_ENOMEM;
			e->bytes += len;
			e->frames_out++;
		}
		if (e->stopping && pl[0].bytesused <= pl[0].data_offset)
			e->eos = 1;
		if (q.flags & V4L2_BUF_FLAG_LAST || e->eos)
			last = 1;
		else if (queue_cap(e, q.index))
			return -1;
	}
	if (FD_ISSET(e->fd, &wr)) {
		struct v4l2_plane pl[1] = { 0 };
		struct v4l2_buffer q = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
					 .memory = V4L2_MEMORY_MMAP, .m.planes = pl, .length = 1 };
		if (!xioctl(e->fd, VIDIOC_DQBUF, &q))
			e->out[q.index].queued = 0;
	}
	return last;
}

static int compat_frame(struct tsvcam_venc *e, const struct tsvcam_frame *fr, uint64_t pts_us)
{
	int i = e->frames_in % e->nout, outs = e->frames_out;

	/* one frame in flight: the previous frame's buffer is back before this */
	if (e->out[i].queued)
		return TSVCAM_EIO;
	trace("venc: write frame %d into OUT index %d\n", e->frames_in, i);
	uint8_t *y = e->out[i].mem;
	rgb_to_nv12(fr, y, e->bpl, y + (size_t)e->bpl * e->scanlines, e->width, e->height);

	struct v4l2_plane pl[1] = { 0 };
	struct v4l2_buffer q = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
				 .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = pl, .length = 1 };
	pl[0].bytesused = (uint32_t)e->frame_size;	/* sizeimage, as v4l2-ctl */
	pl[0].length = e->out[i].len;
	q.timestamp.tv_sec = pts_us / 1000000;
	q.timestamp.tv_usec = pts_us % 1000000;
	q.field = V4L2_FIELD_NONE;
	if (xioctl(e->fd, VIDIOC_QBUF, &q))
		return TSVCAM_EIO;
	e->out[i].queued = 1;
	e->frames_in++;
	if (!e->streaming && compat_start(e))
		return TSVCAM_EIO;
	/* wait for the raw buffer back and its bitstream (3 s at most) */
	for (int k = 0; k < 30 && (e->out[i].queued || e->frames_out == outs); k++)
		if (compat_step(e, 100) < 0 && k > 20)
			break;
	return e->out[i].queued ? TSVCAM_ETIMEDOUT : e->err;
}

int tsvcam_venc_frame(struct tsvcam_venc *e, const struct tsvcam_frame *fr, uint64_t pts_us)
{
	int i, tries = 0;

	if (e->err)
		return e->err;
	if (e->flags & TSVCAM_VENC_V4L2CTL)
		return compat_frame(e, fr, pts_us);
	if (fr->width < e->width || fr->height < e->height)
		return TSVCAM_EINVAL;
	for (;;) {
		for (i = 0; i < e->nout && e->out[i].queued; i++)
			;
		if (i < e->nout)
			break;
		if (reap(e, 1000) < 0 || ++tries > 3)
			return TSVCAM_ETIMEDOUT;
	}
	uint8_t *y = e->out[i].mem;
	rgb_to_nv12(fr, y, e->bpl, y + (size_t)e->bpl * e->scanlines, e->width, e->height);

	struct v4l2_plane pl[1] = { 0 };
	struct v4l2_buffer q = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
				 .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = pl, .length = 1 };
	pl[0].bytesused = e->flags & TSVCAM_VENC_EXACT_BYTES ?
			  (uint32_t)((size_t)e->bpl * e->scanlines * 3 / 2) : (uint32_t)e->out[i].len;
	pl[0].length = e->out[i].len;
	q.timestamp.tv_sec = pts_us / 1000000;
	q.timestamp.tv_usec = pts_us % 1000000;
	q.field = V4L2_FIELD_NONE;
	if (xioctl(e->fd, VIDIOC_QBUF, &q))
		return TSVCAM_EIO;
	e->out[i].queued = 1;
	e->frames_in++;
	if (!e->streaming && start_streams(e)) {
		fprintf(stderr, "tsvcam: encoder start: %s\n", strerror(errno));
		return TSVCAM_EIO;
	}
	reap(e, 0);
	return e->err;
}

size_t tsvcam_venc_bytes(const struct tsvcam_venc *e)
{
	return e->bytes;
}

int tsvcam_venc_finish(struct tsvcam_venc *e, uint8_t **mp4, size_t *len, uint32_t *duration_ms)
{
	struct v4l2_encoder_cmd cmd = { .cmd = V4L2_ENC_CMD_STOP };
	int r = 0, waited = 0;

	e->stopping = 1;
	if (xioctl(e->fd, VIDIOC_ENCODER_CMD, &cmd))
		return TSVCAM_EIO;
	if (e->flags & TSVCAM_VENC_V4L2CTL) {
		for (int k = 0; k < 30 && r != 1; k++)
			r = compat_step(e, 100);
		r = 0;
	} else while (!(r = reap(e, 200))) {
		/* the firmware returns an empty buffer without LAST after a stop */
		if (e->eos && e->frames_out >= e->frames_in)
			break;
		if (++waited > 15)	/* 3 s */
			break;
	}
	if (r < 0)
		return TSVCAM_EIO;
	if (e->err)
		return e->err;
	if (mp4mux_finish(e->mux, mp4, len, duration_ms))
		return TSVCAM_EIO;
	return 0;
}

int tsvcam_venc_frames(const struct tsvcam_venc *e)
{
	return mp4mux_frames(e->mux);
}

/* ---- clip ------------------------------------------------------------------ */

void tsvcam_clip_defaults(struct tsvcam_clip_opts *o)
{
	memset(o, 0, sizeof(*o));
	tsvsel_defaults(&o->sel);
	o->fps = 6;
	o->max_bytes = 1100 * 1024;	/* 1.5 MiB data URL after base64, with room */
	o->bitrate = 0;			/* from the byte budget */
	o->compact_time = 1;
	o->settle_ms = 1000;
}

static double mono_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int tsvcam_clip(const struct tsvcam_clip_opts *o, uint8_t **mp4, size_t *len,
		struct tsvcam_clip_info *info)
{
	struct tsvcam_config cfg;
	struct tsvcam_clip_info inf;
	struct tsvcam_frame fr;
	struct tsvsel sel;
	struct tsvcam_venc *enc = NULL;
	tsvcam *cam;
	int err, r = 0, fps = o->fps > 0 ? o->fps : 6;
	double period = 1000.0 / fps, next;
	int max_frames = o->sel.max_frames > 0 && o->sel.max_frames < TSVCAM_CLIP_MAX_FRAMES ?
			 o->sel.max_frames : TSVCAM_CLIP_MAX_FRAMES;
	struct tsvsel_cfg sc = o->sel;

	memset(&inf, 0, sizeof(inf));
	sc.max_frames = max_frames;
	tsvsel_init(&sel, &sc);

	tsvcam_config_default(&cfg, TSVCAM_MODE_BINNED, TSVCAM_OUT_HALF);
	cfg.min_fps = fps < 10 ? fps : 10;
	cam = tsvcam_open(&cfg, &err);
	if (!cam)
		return err;
	if (o->settle_ms > 0) {
		r = tsvcam_settle(cam, o->settle_ms);
		if (r < 0)
			goto out;
		r = 0;
	}

	/* rate from the budget: the whole budget over the longest clip the
	 * frame limit allows, 80 % to leave room for the overshoot */
	int bitrate = o->bitrate;
	if (bitrate <= 0) {
		double secs = (double)max_frames / fps;
		bitrate = (int)(o->max_bytes * 8 * 0.8 / (secs > 0.5 ? secs : 0.5));
		if (bitrate > 4000000)
			bitrate = 4000000;
		if (bitrate < 200000)
			bitrate = 200000;
	}
	inf.bitrate = o->venc_flags & TSVCAM_VENC_RATE_CTRLS ? bitrate : 0;	/* 0: driver default */

	next = mono_ms();
	for (;;) {
		double wait = next - mono_ms();
		if (wait > 0)
			usleep((useconds_t)(wait * 1000));
		next += period;
		r = tsvcam_next_frame(cam, &fr, 2000);
		if (r)
			break;
		inf.frames_seen++;
		if (!enc) {
			enc = tsvcam_venc_open(fr.width & ~1, fr.height & ~1, fps, bitrate,
					       fps * 10, o->venc_flags, &err);
			if (!enc) {
				r = err;
				break;
			}
			inf.width = fr.width & ~1;
			inf.height = fr.height & ~1;
		}
		float score = tsvsel_score(&sel, fr.luma_grid);
		int why = tsvsel_consider(&sel, fr.luma_grid, fr.timestamp_ns);
		if (why == TSVSEL_DONE) {
			snprintf(inf.stop, sizeof(inf.stop), "%s",
				 sel.kept >= max_frames ? "frames" : "time");
			break;
		}
		if (why == TSVSEL_SKIP)
			continue;
		/* byte budget: stop before a frame that would likely overflow it */
		size_t sofar = tsvcam_venc_bytes(enc);
		size_t avg = inf.frames_kept ? sofar / inf.frames_kept : 0;
		if (inf.frames_kept && sofar + 3 * avg + 4096 > o->max_bytes) {
			snprintf(inf.stop, sizeof(inf.stop), "bytes");
			break;
		}
		uint64_t real_us = (fr.timestamp_ns - sel.t0_ns) / 1000;
		uint64_t pts = o->compact_time ? (uint64_t)inf.frames_kept * 1000000 / fps : real_us;
		r = tsvcam_venc_frame(enc, &fr, pts);
		if (r)
			break;
		inf.kept_ms[inf.frames_kept] = (uint32_t)(real_us / 1000);
		inf.kept_reason[inf.frames_kept] = (uint8_t)why;
		inf.kept_score[inf.frames_kept] = why == TSVSEL_FIRST ? 0 : score;
		if (why == TSVSEL_CHANGE)
			inf.frames_change++;
		else if (why == TSVSEL_HEARTBEAT)
			inf.frames_heartbeat++;
		inf.frames_kept++;
	}
	if (r == TSVCAM_ECOVER) {
		snprintf(inf.stop, sizeof(inf.stop), "cover");
		if (inf.frames_kept)
			r = 0;		/* deliver what was taken before the cover closed */
	}
	if (!r && enc && inf.frames_kept) {
		double t0 = mono_ms();
		r = tsvcam_venc_finish(enc, mp4, len, &inf.duration_ms);
		inf.drain_ms = (float)(mono_ms() - t0);
		inf.frames_encoded = tsvcam_venc_frames(enc);
		inf.bytes = r ? 0 : *len;
	} else if (!r) {
		r = TSVCAM_EIO;
	}
	inf.window_ms = inf.kept_ms[inf.frames_kept ? inf.frames_kept - 1 : 0];
out:
	tsvcam_venc_close(enc);
	tsvcam_close(cam);
	if (info)
		*info = inf;
	return r;
}
