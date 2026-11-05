// SPDX-License-Identifier: MIT
/* Change-based frame selection (see tsvsel.h). */
#include "tsvsel.h"

#include <math.h>
#include <string.h>

#define TOP_CELLS 12

void tsvsel_defaults(struct tsvsel_cfg *cfg)
{
	cfg->threshold = 0.12f;
	cfg->min_gap_s = 1.0f / 6;
	cfg->idle_gap_s = 1.0f;
	cfg->max_s = 5.0f;
	cfg->max_frames = 30;
}

void tsvsel_init(struct tsvsel *s, const struct tsvsel_cfg *cfg)
{
	memset(s, 0, sizeof(*s));
	s->cfg = *cfg;
	if (s->cfg.max_frames > 0 && s->cfg.max_s > 0) {
		float spread = s->cfg.max_s / s->cfg.max_frames;
		if (s->cfg.min_gap_s < spread)
			s->cfg.min_gap_s = spread;
	}
}

static void normalise(const uint8_t *g, float *out)
{
	float sum = 0;

	for (int i = 0; i < TSVSEL_CELLS; i++)
		sum += g[i];
	float mean = sum / TSVSEL_CELLS;
	if (mean < 1.0f)
		mean = 1.0f;		/* black frame: compare absolute levels */
	for (int i = 0; i < TSVSEL_CELLS; i++)
		out[i] = g[i] / mean;
}

static float score_against(const float *ref, const float *cur)
{
	float top[TOP_CELLS] = { 0 };

	for (int i = 0; i < TSVSEL_CELLS; i++) {
		float d = fabsf(cur[i] - ref[i]);
		/* insertion into a small sorted list (descending) */
		if (d <= top[TOP_CELLS - 1])
			continue;
		int j = TOP_CELLS - 1;
		while (j > 0 && top[j - 1] < d) {
			top[j] = top[j - 1];
			j--;
		}
		top[j] = d;
	}
	float sum = 0;
	for (int i = 0; i < TOP_CELLS; i++)
		sum += top[i];
	return sum / TOP_CELLS;
}

float tsvsel_score(const struct tsvsel *s, const uint8_t grid[TSVSEL_CELLS])
{
	float cur[TSVSEL_CELLS];

	if (!s->have_ref)
		return INFINITY;
	normalise(grid, cur);
	return score_against(s->ref, cur);
}

int tsvsel_consider(struct tsvsel *s, const uint8_t grid[TSVSEL_CELLS], uint64_t ts_ns)
{
	float cur[TSVSEL_CELLS];
	int reason = TSVSEL_SKIP;

	if (!s->have_ref) {
		s->t0_ns = ts_ns;
	} else {
		double since_start = (ts_ns - s->t0_ns) / 1e9;
		if ((s->cfg.max_s > 0 && since_start >= s->cfg.max_s) ||
		    (s->cfg.max_frames > 0 && s->kept >= s->cfg.max_frames))
			return TSVSEL_DONE;
	}
	normalise(grid, cur);
	if (!s->have_ref) {
		reason = TSVSEL_FIRST;
		s->last_score = 0;
	} else {
		double since_last = (ts_ns - s->last_ns) / 1e9;
		s->last_score = score_against(s->ref, cur);
		if (s->last_score >= s->cfg.threshold && since_last + 1e-3 >= s->cfg.min_gap_s)
			reason = TSVSEL_CHANGE;
		else if (s->cfg.idle_gap_s > 0 && since_last + 1e-3 >= s->cfg.idle_gap_s)
			reason = TSVSEL_HEARTBEAT;
	}
	if (reason != TSVSEL_SKIP) {
		memcpy(s->ref, cur, sizeof(cur));
		s->have_ref = 1;
		s->last_ns = ts_ns;
		s->kept++;
	}
	return reason;
}
