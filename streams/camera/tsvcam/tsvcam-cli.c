// SPDX-License-Identifier: MIT
/*
 * tsvcam: command-line front end for libtsvcam.
 *
 *   tsvcam cover                          print open/closed (exit 0/3)
 *   tsvcam photo [-o FILE] [--half] [-q Q] [--settle MS]
 *   tsvcam stream [--mode binned|full|crop] [--full] [--fps N] [-n FRAMES]
 *                 [-o DIR | -o -] [--nv12 [--align N]] [-q Q] [-v]
 *
 * stream writes DIR/frame-NNNN.jpg, or with "-o -" concatenated JPEGs
 * (MJPEG) or, with --nv12, raw NV12 frames to stdout. Statistics go to
 * stderr. Exit code 3 means the lens cover is (or became) closed.
 */
#define _GNU_SOURCE
#include "tsvcam.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop;

static void on_signal(int s)
{
	(void)s;
	stop = 1;
}

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int fail(int err)
{
	fprintf(stderr, "tsvcam: %s\n", tsvcam_strerror(err));
	return err == TSVCAM_ECOVER ? 3 : 1;
}

static int write_all(int fd, const void *p, size_t n)
{
	const char *c = p;

	while (n) {
		ssize_t w = write(fd, c, n);
		if (w < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		c += w;
		n -= w;
	}
	return 0;
}

static void usage(void)
{
	fputs("usage: tsvcam cover | bench\n"
	      "       tsvcam photo [-o FILE] [--half] [-q QUALITY] [--settle MS] [-v]\n"
	      "       tsvcam stream [--mode binned|full|crop] [--full] [--fps N] [-n FRAMES]\n"
	      "                     [-o DIR|-] [--nv12 [--align N]] [-q QUALITY] [--rotate DEG] [-v]\n"
	      "       tsvcam clip [-o FILE.mp4|-] [--max-s S] [--max-frames N] [--max-bytes B]\n"
	      "                   [--threshold T] [--idle-gap S] [--min-gap S] [--fps N] [--bitrate B]\n"
	      "                   [--real-time] [--venc-flags F] [-v]\n"
	      "       tsvcam scores [-n N]\n"
	      "       tsvcam venctest [-o FILE.mp4] [-n N] [--size WxH] [--bitrate B] [--flags F]\n"
	      "         (F: 1 frame rate, 2 rate ctrls, 4 GOP, 8 stream ctrls, 16 exact bytes, 32 capture fmt first, 64 early start, 128 v4l2-ctl mode, 256 explicit STREAMOFF)\n", stderr);
}

static void report_usage(void)
{
	struct rusage ru;

	getrusage(RUSAGE_SELF, &ru);
	fprintf(stderr, "tsvcam: cpu user %.2f s sys %.2f s, max rss %ld KiB\n",
		ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6,
		ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6, ru.ru_maxrss);
}

static int cmd_photo(int argc, char **argv)
{
	const char *out = "photo.jpg";
	int half = 0, q = 90, settle = 2500;
	struct tsvcam_frame info;
	uint8_t *jpeg;
	size_t len;
	FILE *f;
	double t0 = now_ms();

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
		else if (!strcmp(argv[i], "--half")) half = 1;
		else if (!strcmp(argv[i], "-q") && i + 1 < argc) q = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--settle") && i + 1 < argc) settle = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-v")) setenv("TSVCAM_VERBOSE", "1", 1);
		else { usage(); return 2; }
	}
	int r = tsvcam_photo(half, q, settle, &jpeg, &len, &info);
	if (r)
		return fail(r);
	f = strcmp(out, "-") ? fopen(out, "wb") : stdout;
	if (!f || fwrite(jpeg, 1, len, f) != len) {
		perror(out);
		return 1;
	}
	if (f != stdout)
		fclose(f);
	free(jpeg);
	fprintf(stderr, "tsvcam: photo %dx%d %zu bytes, exposure %d us gain %.2f wb %.2f/%.2f, "
		"mean %.3f%s, convert %.0f ms, total %.0f ms\n", info.width, info.height, len,
		info.exposure_us, info.gain, info.wb_r, info.wb_b, info.mean,
		info.converged ? "" : " (AE not converged)", info.process_ms, now_ms() - t0);
	report_usage();
	return 0;
}

static int cmd_stream(int argc, char **argv)
{
	struct tsvcam_config cfg;
	const char *out = NULL, *mode = "binned";
	int full = 0, fps = 6, n = 30, q = 85, nv12 = 0, rotate = -1, verbose = 0, align = 2;
	double conv_ms = 0, jpeg_ms = 0, bytes = 0;
	int frames = 0, err, r = 0;
	uint8_t *nvbuf = NULL;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
		else if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = argv[++i];
		else if (!strcmp(argv[i], "--full")) full = 1;
		else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-q") && i + 1 < argc) q = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--nv12")) nv12 = 1;
		else if (!strcmp(argv[i], "--align") && i + 1 < argc) align = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--rotate") && i + 1 < argc) rotate = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-v")) verbose = 1;
		else { usage(); return 2; }
	}
	tsvcam_config_default(&cfg, !strcmp(mode, "full") ? TSVCAM_MODE_FULL :
			      !strcmp(mode, "crop") ? TSVCAM_MODE_CROP : TSVCAM_MODE_BINNED,
			      full ? TSVCAM_OUT_FULL : TSVCAM_OUT_HALF);
	cfg.rotate = rotate;
	cfg.verbose = verbose;
	if (fps > 0 && fps < cfg.min_fps)
		cfg.min_fps = fps;
	tsvcam *cam = tsvcam_open(&cfg, &err);
	if (!cam)
		return fail(err);

	double period = fps > 0 ? 1000.0 / fps : 0, next = now_ms(), t_start = next;
	while (!stop && (n <= 0 || frames < n)) {
		struct tsvcam_frame fr;
		double t;

		if (period > 0) {
			double wait = next - now_ms();
			if (wait > 0)
				usleep((useconds_t)(wait * 1000));
			next += period;
		}
		r = tsvcam_next_frame(cam, &fr, 2000);
		if (r)
			break;
		conv_ms += fr.process_ms;
		frames++;
		if (nv12) {
			/* crop right/bottom to a multiple of align (video encoders want 16) */
			if (align > 1) {
				fr.width -= fr.width % align;
				fr.height -= fr.height % align;
			}
			size_t sz = (size_t)fr.width * fr.height * 3 / 2;
			if (!nvbuf && !(nvbuf = malloc(sz))) { r = TSVCAM_ENOMEM; break; }
			t = now_ms();
			tsvcam_nv12(&fr, nvbuf);
			jpeg_ms += now_ms() - t;
			bytes += sz;
			if (out && !strcmp(out, "-") && write_all(1, nvbuf, sz)) break;
			continue;
		}
		const uint8_t *j;
		size_t len;
		t = now_ms();
		r = tsvcam_jpeg(cam, &fr, q, &j, &len);
		jpeg_ms += now_ms() - t;
		if (r)
			break;
		bytes += len;
		if (out && !strcmp(out, "-")) {
			if (write_all(1, j, len)) break;
		} else if (out) {
			char path[512];
			FILE *f;
			snprintf(path, sizeof(path), "%s/frame-%04d.jpg", out, frames);
			f = fopen(path, "wb");
			if (!f || fwrite(j, 1, len, f) != len) { perror(path); r = TSVCAM_EIO; break; }
			fclose(f);
		}
		if (frames == 1 || frames % 10 == 0)
			fprintf(stderr, "tsvcam: frame %d seq %u %dx%d exp %d us gain %.2f wb %.2f/%.2f mean %.3f%s\n",
				frames, fr.sequence, fr.width, fr.height, fr.exposure_us, fr.gain,
				fr.wb_r, fr.wb_b, fr.mean, fr.converged ? " ok" : "");
	}
	double secs = (now_ms() - t_start) / 1000.0;
	tsvcam_close(cam);
	free(nvbuf);
	fprintf(stderr, "tsvcam: %d frames in %.2f s (%.2f fps), convert %.1f ms/frame, %s %.1f ms/frame, "
		"%.0f bytes/frame\n", frames, secs, frames / (secs > 0 ? secs : 1),
		frames ? conv_ms / frames : 0, nv12 ? "nv12" : "jpeg", frames ? jpeg_ms / frames : 0,
		frames ? bytes / frames : 0);
	report_usage();
	return r ? fail(r) : 0;
}

static const char *reason_name(int r)
{
	switch (r) {
	case TSVSEL_FIRST: return "first";
	case TSVSEL_CHANGE: return "change";
	case TSVSEL_HEARTBEAT: return "heartbeat";
	}
	return "-";
}

static int cmd_clip(int argc, char **argv)
{
	struct tsvcam_clip_opts o;
	struct tsvcam_clip_info info;
	const char *out = "clip.mp4";
	int verbose = 0;
	uint8_t *mp4;
	size_t len;
	double t0 = now_ms();

	tsvcam_clip_defaults(&o);
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
		else if (!strcmp(argv[i], "--max-s") && i + 1 < argc) o.sel.max_s = (float)atof(argv[++i]);
		else if (!strcmp(argv[i], "--max-frames") && i + 1 < argc) o.sel.max_frames = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--max-bytes") && i + 1 < argc) o.max_bytes = (size_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--threshold") && i + 1 < argc) o.sel.threshold = (float)atof(argv[++i]);
		else if (!strcmp(argv[i], "--idle-gap") && i + 1 < argc) o.sel.idle_gap_s = (float)atof(argv[++i]);
		else if (!strcmp(argv[i], "--min-gap") && i + 1 < argc) o.sel.min_gap_s = (float)atof(argv[++i]);
		else if (!strcmp(argv[i], "--fps") && i + 1 < argc) o.fps = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--bitrate") && i + 1 < argc) o.bitrate = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--real-time")) o.compact_time = 0;
		else if (!strcmp(argv[i], "--venc-flags") && i + 1 < argc) o.venc_flags = (unsigned)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "-v")) verbose = 1;
		else { usage(); return 2; }
	}
	int r = tsvcam_clip(&o, &mp4, &len, &info);
	if (r)
		return fail(r);
	FILE *f = strcmp(out, "-") ? fopen(out, "wb") : stdout;
	if (!f || fwrite(mp4, 1, len, f) != len) {
		perror(out);
		return 1;
	}
	if (f != stdout)
		fclose(f);
	free(mp4);
	fprintf(stderr, "tsvcam: clip %dx%d, %d of %d frames kept (%d change, %d heartbeat), stop %s, "
		"window %u ms, mp4 %u ms, %zu bytes, bitrate %d (0 = driver default), encoder drain %.0f ms, total %.0f ms\n",
		info.width, info.height, info.frames_kept, info.frames_seen, info.frames_change,
		info.frames_heartbeat, info.stop[0] ? info.stop : "-", info.window_ms, info.duration_ms,
		info.bytes, info.bitrate, info.drain_ms, now_ms() - t0);
	if (verbose)
		for (int i = 0; i < info.frames_kept; i++)
			fprintf(stderr, "tsvcam:   %2d  t=%5u ms  %-9s score %.3f\n", i, info.kept_ms[i],
				reason_name(info.kept_reason[i]), info.kept_score[i]);
	report_usage();
	return 0;
}

/* Venus encode of synthetic moving frames, no camera: the encoder alone. */
static int cmd_venctest(int argc, char **argv)
{
	int w = 490, h = 652, n = 30, fps = 6, bitrate = 300000, err;
	unsigned flags = 0;
	const char *out = "venctest.mp4";

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
		else if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--size") && i + 1 < argc) sscanf(argv[++i], "%dx%d", &w, &h);
		else if (!strcmp(argv[i], "--bitrate") && i + 1 < argc) bitrate = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--flags") && i + 1 < argc) flags = (unsigned)strtoul(argv[++i], NULL, 0);
		else { usage(); return 2; }
	}
	uint8_t *rgb = malloc((size_t)w * h * 3);
	if (!rgb)
		return fail(TSVCAM_ENOMEM);
	double t0 = now_ms();
	tsvcam_venc *e = tsvcam_venc_open(w, h, fps, bitrate, fps * 10, flags, &err);
	if (!e) {
		free(rgb);
		return fail(err);
	}
	struct tsvcam_frame fr = { .rgb = rgb, .width = w, .height = h, .stride = w * 3 };
	for (int i = 0; i < n && !err; i++) {
		for (int y = 0; y < h; y++)		/* gradient with a moving bar */
			for (int x = 0; x < w; x++) {
				uint8_t *p = rgb + ((size_t)y * w + x) * 3;
				int bar = ((x + i * 8) % w) < 40;
				p[0] = bar ? 240 : (uint8_t)(x * 255 / w);
				p[1] = bar ? 240 : (uint8_t)(y * 255 / h);
				p[2] = bar ? 40 : 128;
			}
		err = tsvcam_venc_frame(e, &fr, (uint64_t)i * 1000000 / fps);
	}
	uint8_t *mp4 = NULL;
	size_t len = 0;
	uint32_t dms = 0;
	if (!err)
		err = tsvcam_venc_finish(e, &mp4, &len, &dms);
	int frames = tsvcam_venc_frames(e);
	tsvcam_venc_close(e);
	free(rgb);
	if (err)
		return fail(err);
	FILE *f = fopen(out, "wb");
	if (!f || fwrite(mp4, 1, len, f) != len) {
		perror(out);
		return 1;
	}
	fclose(f);
	free(mp4);
	fprintf(stderr, "tsvcam: venctest %dx%d %d frames in, %d out, %zu bytes, %u ms, %.0f ms wall\n",
		w, h, n, frames, len, dms, now_ms() - t0);
	report_usage();
	return 0;
}

/* Scores of every frame against the previous one and against the first:
 * the noise floor of a still scene, for choosing the threshold. */
static int cmd_scores(int argc, char **argv)
{
	struct tsvcam_config cfg;
	struct tsvsel_cfg sc;
	struct tsvsel first, prev;
	int n = 36, err;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atoi(argv[++i]);
		else { usage(); return 2; }
	}
	tsvcam_config_default(&cfg, TSVCAM_MODE_BINNED, TSVCAM_OUT_HALF);
	cfg.min_fps = 6;
	tsvcam *cam = tsvcam_open(&cfg, &err);
	if (!cam)
		return fail(err);
	tsvcam_settle(cam, 1000);
	tsvsel_defaults(&sc);
	sc.threshold = 1e9f;	/* never keep on change: only the scores */
	sc.idle_gap_s = 0;
	sc.max_s = 0;
	sc.max_frames = 0;
	tsvsel_init(&first, &sc);
	double next = now_ms(), maxp = 0, maxf = 0, sump = 0;
	for (int i = 0; i < n; i++) {
		struct tsvcam_frame fr;
		double wait = next - now_ms();
		if (wait > 0)
			usleep((useconds_t)(wait * 1000));
		next += 1000.0 / 6;
		int r = tsvcam_next_frame(cam, &fr, 2000);
		if (r) {
			tsvcam_close(cam);
			return fail(r);
		}
		if (i == 0) {
			tsvsel_consider(&first, fr.luma_grid, fr.timestamp_ns);
			tsvsel_init(&prev, &sc);
		}
		float sp = i ? tsvsel_score(&prev, fr.luma_grid) : 0, sf = i ? tsvsel_score(&first, fr.luma_grid) : 0;
		/* prev's reference becomes this frame */
		struct tsvsel_cfg one = sc;
		one.threshold = 0;
		one.min_gap_s = 0;
		prev.cfg = one;
		tsvsel_consider(&prev, fr.luma_grid, fr.timestamp_ns);
		if (sp > maxp) maxp = sp;
		if (sf > maxf) maxf = sf;
		sump += sp;
		printf("%3d  vs previous %.3f  vs first %.3f  exp %d us gain %.2f\n", i, sp, sf,
		       fr.exposure_us, fr.gain);
	}
	printf("max vs previous %.3f (mean %.3f), max vs first %.3f\n", maxp, n > 1 ? sump / (n - 1) : 0, maxf);
	tsvcam_close(cam);
	return 0;
}

int main(int argc, char **argv)
{
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, on_signal);
	if (argc < 2) {
		usage();
		return 2;
	}
	if (!strcmp(argv[1], "cover")) {
		int r = tsvcam_cover_closed();
		if (r < 0)
			return fail(r);
		puts(r ? "closed" : "open");
		return r ? 3 : 0;
	}
	if (!strcmp(argv[1], "bench")) {
		static const char *names[] = { "full 2608x1960", "binned 1304x980", "crop 1936x1096" };
		for (int m = 0; m < 3; m++)
			for (int o = 0; o < 2; o++) {
				double c, j;
				int r = tsvcam_bench(m, o, 90, 5, &c, &j);
				if (r)
					return fail(r);
				printf("%-16s %-8s convert %6.1f ms  jpeg %6.1f ms\n", names[m],
				       o ? "demosaic" : "quad", c, j);
			}
		return 0;
	}
	if (!strcmp(argv[1], "photo"))
		return cmd_photo(argc - 1, argv + 1);
	if (!strcmp(argv[1], "stream"))
		return cmd_stream(argc - 1, argv + 1);
	if (!strcmp(argv[1], "clip"))
		return cmd_clip(argc - 1, argv + 1);
	if (!strcmp(argv[1], "venctest"))
		return cmd_venctest(argc - 1, argv + 1);
	if (!strcmp(argv[1], "scores"))
		return cmd_scores(argc - 1, argv + 1);
	usage();
	return 2;
}
