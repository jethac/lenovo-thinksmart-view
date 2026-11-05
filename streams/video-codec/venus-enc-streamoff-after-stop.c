// SPDX-License-Identifier: MIT
/*
 * Reproducer: VIDIOC_STREAMOFF on the Venus H.264 encoder's OUTPUT queue,
 * after V4L2_ENC_CMD_STOP whose drain never completed, wedges the whole SoC
 * on MSM8953 (Lenovo ThinkSmart View, Linux 7.3 baseline #10). Nothing is
 * logged; the hardware watchdog resets the board.
 *
 * On this firmware (VIDEO.VE.4.2-00078, HFI 3xx) the stop is answered with
 * one empty CAPTURE buffer without V4L2_BUF_FLAG_LAST, so the driver stays
 * in VENUS_ENC_STATE_DRAIN. Closing the file descriptor instead of
 * STREAMOFF (what v4l2-ctl does; the m2m release stops CAPTURE first)
 * does not hang.
 *
 * DO NOT RUN without the device lock and an agreed driver investigation:
 * it hangs the tablet.
 *
 * Every control at its default.
 * Build: clang --target=aarch64-linux-gnu --sysroot=<sysroot> -O2 -o repro venus-enc-streamoff-after-stop.c
 * Run:   repro /dev/videoN      (the node whose name is qcom-venus-encoder)
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define W 490
#define H 652
#define NBUF 4
#define FRAMES 30

static int fd;

static int x(unsigned long req, void *arg, const char *what)
{
	int r = ioctl(fd, req, arg);

	fprintf(stderr, "%s: %s\n", what, r ? strerror(errno) : "ok");
	return r;
}

static void map(enum v4l2_buf_type type, void **mem, unsigned *len)
{
	struct v4l2_requestbuffers rb = { .count = NBUF, .type = type, .memory = V4L2_MEMORY_MMAP };

	if (x(VIDIOC_REQBUFS, &rb, "REQBUFS"))
		_exit(1);
	for (unsigned i = 0; i < NBUF; i++) {
		struct v4l2_plane pl[1] = { 0 };
		struct v4l2_buffer b = { .type = type, .memory = V4L2_MEMORY_MMAP, .index = i,
					 .m.planes = pl, .length = 1 };
		if (x(VIDIOC_QUERYBUF, &b, "QUERYBUF"))
			_exit(1);
		len[i] = pl[0].length;
		mem[i] = mmap(NULL, len[i], PROT_READ | PROT_WRITE, MAP_SHARED, fd, pl[0].m.mem_offset);
	}
}

static void qbuf(enum v4l2_buf_type type, unsigned i, unsigned bytes, unsigned len)
{
	struct v4l2_plane pl[1] = { { .bytesused = bytes, .length = len } };
	struct v4l2_buffer b = { .type = type, .memory = V4L2_MEMORY_MMAP, .index = i,
				 .m.planes = pl, .length = 1 };
	ioctl(fd, VIDIOC_QBUF, &b);
}

static int dqbuf(enum v4l2_buf_type type, unsigned *idx, unsigned *bytes, unsigned *flags)
{
	struct v4l2_plane pl[1] = { 0 };
	struct v4l2_buffer b = { .type = type, .memory = V4L2_MEMORY_MMAP, .m.planes = pl, .length = 1 };

	if (ioctl(fd, VIDIOC_DQBUF, &b))
		return -1;
	*idx = b.index;
	*bytes = pl[0].bytesused;
	*flags = b.flags;
	return 0;
}

int main(int argc, char **argv)
{
	struct v4l2_format f;
	void *out[NBUF], *cap[NBUF];
	unsigned olen[NBUF], clen[NBUF], idx, bytes, flags, done = 0, sent = 0;
	enum v4l2_buf_type t;

	if (argc < 2) {
		fprintf(stderr, "usage: %s /dev/videoN (qcom-venus-encoder)\n", argv[0]);
		return 2;
	}
	fd = open(argv[1], O_RDWR | O_NONBLOCK);
	if (fd < 0)
		return 1;
	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	f.fmt.pix_mp.width = W; f.fmt.pix_mp.height = H;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12; f.fmt.pix_mp.num_planes = 1;
	x(VIDIOC_S_FMT, &f, "S_FMT OUTPUT");
	memset(&f, 0, sizeof(f));
	f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	f.fmt.pix_mp.width = W; f.fmt.pix_mp.height = H;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_H264; f.fmt.pix_mp.num_planes = 1;
	x(VIDIOC_S_FMT, &f, "S_FMT CAPTURE");

	/* the order v4l2-ctl uses: first frame, OUTPUT on, CAPTURE set up, on */
	map(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, out, olen);
	memset(out[0], 0x80, olen[0]);
	qbuf(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, 0, olen[0], olen[0]);
	sent = 1;
	t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	x(VIDIOC_STREAMON, &t, "STREAMON OUTPUT");
	map(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, cap, clen);
	for (unsigned i = 0; i < NBUF; i++)
		qbuf(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, i, 0, clen[i]);
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	x(VIDIOC_STREAMON, &t, "STREAMON CAPTURE");

	/* encode FRAMES grey frames, one output buffer recycled at a time */
	while (done < FRAMES) {
		struct pollfd p = { .fd = fd, .events = POLLIN | POLLOUT };
		if (poll(&p, 1, 2000) <= 0)
			break;
		if (!dqbuf(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, &idx, &bytes, &flags)) {
			done++;
			qbuf(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, idx, 0, clen[idx]);
		}
		if (!dqbuf(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, &idx, &bytes, &flags) && sent < FRAMES) {
			qbuf(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, idx, olen[idx], olen[idx]);
			sent++;
		}
	}
	fprintf(stderr, "%u frames encoded\n", done);

	/* stop: the firmware returns one empty CAPTURE buffer without LAST */
	struct v4l2_encoder_cmd cmd = { .cmd = V4L2_ENC_CMD_STOP };
	x(VIDIOC_ENCODER_CMD, &cmd, "ENCODER_CMD STOP");
	for (int k = 0; k < 15; k++) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		poll(&p, 1, 200);
		if (!dqbuf(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, &idx, &bytes, &flags))
			fprintf(stderr, "CAPTURE index %u bytesused %u flags 0x%x%s\n", idx, bytes, flags,
				flags & V4L2_BUF_FLAG_LAST ? " LAST" : "");
	}

	/* this call wedged the SoC */
	t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	x(VIDIOC_STREAMOFF, &t, "STREAMOFF OUTPUT");
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	x(VIDIOC_STREAMOFF, &t, "STREAMOFF CAPTURE");
	close(fd);
	return 0;
}
