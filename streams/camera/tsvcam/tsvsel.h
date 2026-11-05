/* SPDX-License-Identifier: MIT */
/*
 * Change-based frame selection on the 16x12 luma grid that tsvcam returns
 * with every frame (tsvcam_frame.luma_grid).
 *
 * Each grid is divided by its own mean, so AE moving the overall level is
 * not change. A frame's score is the mean absolute difference, against the
 * last kept frame, of its most-changed cells (the top 6 %, 12 of 192), so a
 * hand or a face moving in a small part of the view counts as much as a
 * whole-scene change. Comparing with the last kept frame (not the previous
 * one) means slow drift also triggers once it adds up.
 *
 *   keep the first frame;
 *   keep a frame if score >= threshold and at least min_gap since the last kept;
 *   keep a frame if idle_gap > 0 and that long has passed (heartbeat);
 *   stop once max_frames or max_s is reached (the caller also stops on bytes).
 *
 * Nothing changing: the clip is the first frame plus one frame per idle_gap.
 * Everything changing: one frame per min_gap, with min_gap at least
 * max_s / max_frames so the frame budget covers the whole window instead of
 * being spent in the first second.
 */
#ifndef TSVSEL_H
#define TSVSEL_H

#include <stdint.h>

#define TSVSEL_CELLS (16 * 12)

struct tsvsel_cfg {
	float threshold;	/* score that counts as change (default 0.12) */
	float min_gap_s;	/* at least this between kept frames (default 1/6 s) */
	float idle_gap_s;	/* heartbeat when nothing changes; 0 = none (default 1.0) */
	float max_s;		/* window length (default 5) */
	int max_frames;		/* frames per clip (default 30) */
};

struct tsvsel {
	struct tsvsel_cfg cfg;
	float ref[TSVSEL_CELLS];
	int have_ref;
	uint64_t t0_ns, last_ns;
	int kept;
	float last_score;
};

enum tsvsel_reason {
	TSVSEL_SKIP = 0,
	TSVSEL_FIRST = 1,
	TSVSEL_CHANGE = 2,
	TSVSEL_HEARTBEAT = 3,
	TSVSEL_DONE = -1,	/* window or frame budget used up */
};

void tsvsel_defaults(struct tsvsel_cfg *cfg);
void tsvsel_init(struct tsvsel *s, const struct tsvsel_cfg *cfg);
/* Decide on one frame; returns enum tsvsel_reason. */
int tsvsel_consider(struct tsvsel *s, const uint8_t grid[TSVSEL_CELLS], uint64_t ts_ns);
/* Score of grid against the reference without changing state. */
float tsvsel_score(const struct tsvsel *s, const uint8_t grid[TSVSEL_CELLS]);

#endif
