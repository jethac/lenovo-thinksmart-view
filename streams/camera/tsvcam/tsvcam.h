/* SPDX-License-Identifier: MIT */
/*
 * tsvcam: colour frames and JPEG stills from the ThinkSmart View front camera
 * (Samsung S5KC505A behind Qualcomm CAMSS RDI0, raw Bayer only).
 *
 * The library sets up the media pipeline itself (no media-ctl), captures
 * packed RAW10 GRBG frames and turns them into 8-bit RGB on the CPU:
 * black level, auto exposure (sensor exposure, analogue gain, frame length),
 * grey-world white balance, a saturation matrix, sRGB gamma and the mount
 * rotation. JPEG encoding is libjpeg-turbo.
 *
 * One handle at a time (the CAMSS pipeline is exclusive). Not thread safe:
 * call a handle from one thread. Nothing is written to disk by the library.
 */
#ifndef TSVCAM_H
#define TSVCAM_H

#include <stddef.h>
#include <stdint.h>

#include "tsvsel.h"

#ifdef __cplusplus
extern "C" {
#endif

enum tsvcam_error {
	TSVCAM_OK = 0,
	TSVCAM_ECOVER = -1,	/* lens cover closed: nothing captured */
	TSVCAM_ENODEV = -2,	/* no CAMSS media device or sensor */
	TSVCAM_EBUSY = -3,	/* pipeline in use by another process */
	TSVCAM_EIO = -4,	/* V4L2/media ioctl failed (errno kept) */
	TSVCAM_ETIMEDOUT = -5,	/* no frame within the timeout */
	TSVCAM_ENOMEM = -6,
	TSVCAM_EINVAL = -7,
	TSVCAM_EJPEG = -8,
};

/* Sensor readout modes (all 30 fps at the shortest frame length). */
enum tsvcam_mode {
	TSVCAM_MODE_FULL = 0,	/* 2608x1960, full array */
	TSVCAM_MODE_BINNED = 1,	/* 1304x980, 2x2 binned full array */
	TSVCAM_MODE_CROP = 2,	/* 1936x1096, centre crop (16:9) */
};

/* How a raw frame becomes RGB. */
enum tsvcam_output {
	TSVCAM_OUT_HALF = 0,	/* one RGB pixel per 2x2 Bayer quad: W/2 x H/2 */
	TSVCAM_OUT_FULL = 1,	/* bilinear demosaic: W x H */
};

struct tsvcam_config {
	int mode;		/* enum tsvcam_mode */
	int output;		/* enum tsvcam_output */
	int rotate;		/* clockwise degrees 0/90/180/270; -1 = from the sensor's DT rotation */
	int min_fps;		/* frame length may grow until the sensor runs this slow (default 10) */
	int max_exposure_us;	/* exposure cap before gain is raised (default 66000) */
	int flicker_hz;		/* 50 or 60: exposures above one period snap to multiples; 0 = off */
	float saturation;	/* 1.0 = none, default 1.35 */
	float ae_target;	/* mean linear green, default 0.16 */
	int buffers;		/* V4L2 buffers, default 3 */
	int verbose;		/* 1: per-frame AE/AWB on stderr */
};

/* Fill with defaults for a mode/output. */
void tsvcam_config_default(struct tsvcam_config *cfg, int mode, int output);

#define TSVCAM_GRID_W 16
#define TSVCAM_GRID_H 12

struct tsvcam_frame {
	const uint8_t *rgb;	/* packed RGB24, valid until the next call on the handle */
	int width, height, stride;
	uint32_t sequence;	/* sensor frame counter from the driver */
	uint64_t timestamp_ns;	/* CLOCK_MONOTONIC, start of frame */
	int exposure_us;
	float gain;		/* analogue x digital */
	float wb_r, wb_b;	/* white balance gains relative to green */
	float mean;		/* mean linear green in [0,1] before this frame's AE step */
	int converged;		/* AE within tolerance */
	float process_ms;	/* CPU time spent turning this frame into RGB */
	/*
	 * Mean linear green on a 16x12 grid over the sensor (unrotated, before
	 * white balance), 0..255. From the AE samples, so free; meant for
	 * change detection between frames (normalise by the frame mean, since
	 * AE moves the overall level).
	 */
	uint8_t luma_grid[TSVCAM_GRID_W * TSVCAM_GRID_H];
};

typedef struct tsvcam tsvcam;

/* 1 if the lens cover reads closed, 0 if open, negative tsvcam_error on failure. */
int tsvcam_cover_closed(void);

/* Open the camera and start streaming. Fails with TSVCAM_ECOVER when the
 * cover is closed. *err gets the error code if the result is NULL. */
tsvcam *tsvcam_open(const struct tsvcam_config *cfg, int *err);

/* Wait for the next frame that is newer than the last one returned (older
 * queued frames are dropped, so the caller sets the pace) and convert it.
 * Returns TSVCAM_ECOVER and stops the stream if the cover was closed. */
int tsvcam_next_frame(tsvcam *cam, struct tsvcam_frame *frame, int timeout_ms);

/* Run auto exposure / white balance without converting frames, until AE has
 * converged (or timeout_ms passes). Returns frames consumed or an error. */
int tsvcam_settle(tsvcam *cam, int timeout_ms);

/* JPEG-encode a frame. *jpeg points into the handle (valid until the next
 * encode or close). quality 1..100. */
int tsvcam_jpeg(tsvcam *cam, const struct tsvcam_frame *frame, int quality,
		const uint8_t **jpeg, size_t *len);

/* Convert a frame to NV12 (BT.601 limited range) into dst, which must hold
 * width*height*3/2 bytes; width and height must be even. */
int tsvcam_nv12(const struct tsvcam_frame *frame, uint8_t *dst);

/* Stop streaming and release everything. */
void tsvcam_close(tsvcam *cam);

/*
 * One still: open in full mode, settle AE/AWB (up to settle_ms), take one
 * frame, encode, close. half != 0 gives 1304x980 (quad binning of the full
 * readout, cleaner than demosaicing) instead of 2608x1960. The JPEG is
 * malloc()ed; free() it.
 */
int tsvcam_photo(int half, int quality, int settle_ms, uint8_t **jpeg, size_t *len,
		 struct tsvcam_frame *info);

const char *tsvcam_strerror(int err);

/* Conversion and JPEG (quality 85) CPU time per frame on a synthetic raw
 * frame, without opening the camera. */
int tsvcam_bench(int mode, int output, int rotate, int iters, double *convert_ms, double *jpeg_ms);

/* ---- H.264 on the Venus encoder (V4L2 mem2mem) and MP4 clips ------------- */

typedef struct tsvcam_venc tsvcam_venc;

/*
 * Encoder settings beyond the formats. The default (0) drives the encoder
 * exactly as the tested v4l2-ctl runs did: formats OUTPUT then CAPTURE,
 * driver default rate control (about 1 Mbit/s), no frame interval, full
 * buffers, and the queues started in v4l2-ctl's order (first raw frame
 * queued, OUTPUT on, CAPTURE buffers allocated and queued, CAPTURE on). Two runs with the extra settings hung the tablet on 2026-11-04
 * (see NOTES.md); each flag turns one back on, for finding the culprit.
 */
enum tsvcam_venc_flags {
	TSVCAM_VENC_FRAME_RATE = 1 << 0,	/* VIDIOC_S_PARM with 1/fps */
	TSVCAM_VENC_RATE_CTRLS = 1 << 1,	/* VBR mode and bitrate */
	TSVCAM_VENC_GOP_CTRL = 1 << 2,		/* GOP size */
	TSVCAM_VENC_STREAM_CTRLS = 1 << 3,	/* B-frames 0, Main profile, header mode */
	TSVCAM_VENC_EXACT_BYTES = 1 << 4,	/* bytesused = frame data, not the whole buffer */
	TSVCAM_VENC_CAPTURE_FIRST = 1 << 5,	/* set the CAPTURE format before OUTPUT */
	TSVCAM_VENC_EARLY_START = 1 << 6,	/* allocate and stream on both queues at open,
						 * before any frame (hung the tablet) */
	TSVCAM_VENC_EXPLICIT_STREAMOFF = 1 << 8,	/* STREAMOFF both queues at close (hung the
						 * tablet after an unfinished drain) */
	TSVCAM_VENC_V4L2CTL = 1 << 7,		/* drive it like v4l2-ctl: blocking fd, select(),
						 * one frame in flight, bytesused = sizeimage,
						 * CAPTURE format set again after OUTPUT starts */
};

/* Open the hardware encoder for frames of width x height (even), nominal
 * fps, bitrate (bit/s) and a keyframe every gop frames; bitrate and gop only
 * apply with the matching flags. */
tsvcam_venc *tsvcam_venc_open(int width, int height, int fps, int bitrate, int gop,
			      unsigned flags, int *err);
/* Encode one frame (RGB from tsvcam_next_frame, converted to NV12 in the
 * encoder's own buffer); pts_us becomes the frame's MP4 timestamp. */
int tsvcam_venc_frame(tsvcam_venc *e, const struct tsvcam_frame *frame, uint64_t pts_us);
/* Bitstream bytes produced so far (lags the queued frames by a frame or two). */
size_t tsvcam_venc_bytes(const tsvcam_venc *e);
int tsvcam_venc_frames(const tsvcam_venc *e);
/* Drain the encoder and return an MP4 (malloc()ed; free() it). */
int tsvcam_venc_finish(tsvcam_venc *e, uint8_t **mp4, size_t *len, uint32_t *duration_ms);
void tsvcam_venc_close(tsvcam_venc *e);

#define TSVCAM_CLIP_MAX_FRAMES 120

struct tsvcam_clip_opts {
	struct tsvsel_cfg sel;	/* change threshold, gaps, max_s, max_frames */
	size_t max_bytes;	/* MP4 size limit (default 1100 KiB: a 1.5 MiB data URL) */
	int fps;		/* sampling rate (default 6) */
	int bitrate;		/* 0: derived from max_bytes and max_frames */
	int compact_time;	/* 1 (default): kept frames 1/fps apart in the MP4, real
				 * capture times in tsvcam_clip_info; 0: real times */
	int settle_ms;		/* AE/AWB settling before the window starts (default 1000) */
	unsigned venc_flags;	/* enum tsvcam_venc_flags, default 0 */
};

struct tsvcam_clip_info {
	int width, height, bitrate;
	int frames_seen, frames_kept, frames_change, frames_heartbeat, frames_encoded;
	uint32_t duration_ms;	/* of the MP4 */
	uint32_t window_ms;	/* capture time of the last kept frame */
	size_t bytes;
	float drain_ms;
	char stop[8];		/* "time", "frames", "bytes", "cover" */
	uint32_t kept_ms[TSVCAM_CLIP_MAX_FRAMES];	/* capture time of each kept frame */
	uint8_t kept_reason[TSVCAM_CLIP_MAX_FRAMES];	/* enum tsvsel_reason */
	float kept_score[TSVCAM_CLIP_MAX_FRAMES];
};

void tsvcam_clip_defaults(struct tsvcam_clip_opts *o);
/* Open the camera (binned readout, 490x652), settle, sample at fps for up to
 * sel.max_s, keep frames by change, encode on Venus and return an MP4.
 * Refuses with TSVCAM_ECOVER if the cover is closed; if it closes during the
 * clip, the frames taken so far are returned (info->stop = "cover"). */
int tsvcam_clip(const struct tsvcam_clip_opts *o, uint8_t **mp4, size_t *len,
		struct tsvcam_clip_info *info);

#ifdef __cplusplus
}
#endif
#endif
