/* SPDX-License-Identifier: MIT */
/* Minimal in-memory MP4 writer for one H.264 track (see mp4mux.c). */
#ifndef TSVCAM_MP4MUX_H
#define TSVCAM_MP4MUX_H

#include <stddef.h>
#include <stdint.h>

struct mp4mux;

struct mp4mux *mp4mux_new(int width, int height, int fps);
/* One access unit in Annex B form (SPS/PPS may be inside; they go to avcC).
 * Returns 1 if a sample was added, 0 for parameter sets only, -1 on error. */
int mp4mux_add(struct mp4mux *m, const uint8_t *au, size_t len, uint64_t pts_us);
int mp4mux_frames(const struct mp4mux *m);
size_t mp4mux_bytes(const struct mp4mux *m);
/* The whole file (malloc'ed). Fails without SPS/PPS or samples. */
int mp4mux_finish(struct mp4mux *m, uint8_t **out, size_t *len, uint32_t *duration_ms);
void mp4mux_free(struct mp4mux *m);

#endif
