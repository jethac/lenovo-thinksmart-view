// SPDX-License-Identifier: MIT
/*
 * Minimal MP4 writer for one H.264 video track, in memory: takes Annex B
 * access units with timestamps, keeps SPS/PPS for the avcC box and writes
 * ftyp + moov + mdat ("fast start", the index first). One chunk, variable
 * frame durations from the timestamps, sync samples from IDR slices.
 */
#include "mp4mux.h"

#include <stdlib.h>
#include <string.h>

#define TIMESCALE 90000		/* media timescale (ticks per second) */
#define MOVIE_TIMESCALE 1000

struct sample {
	size_t off, len;
	uint64_t pts_us;
	int key;
};

struct mp4mux {
	int width, height;
	uint32_t default_dur_us;
	uint8_t *sps, *pps;
	size_t sps_len, pps_len;
	uint8_t *mdat;
	size_t mdat_len, mdat_cap;
	struct sample *s;
	int n, cap;
};

struct buf {
	uint8_t *p;
	size_t len, cap;
	int err;
};

static void put(struct buf *b, const void *d, size_t n)
{
	if (b->err)
		return;
	if (b->len + n > b->cap) {
		size_t c = b->cap ? b->cap * 2 : 4096;
		while (c < b->len + n)
			c *= 2;
		uint8_t *p = realloc(b->p, c);
		if (!p) {
			b->err = 1;
			return;
		}
		b->p = p;
		b->cap = c;
	}
	memcpy(b->p + b->len, d, n);
	b->len += n;
}

static void u8(struct buf *b, uint8_t v) { put(b, &v, 1); }
static void u16(struct buf *b, uint16_t v) { uint8_t d[2] = { v >> 8, v }; put(b, d, 2); }
static void u32(struct buf *b, uint32_t v) { uint8_t d[4] = { v >> 24, v >> 16, v >> 8, v }; put(b, d, 4); }
static void zeros(struct buf *b, size_t n) { while (n--) u8(b, 0); }

static size_t box_open(struct buf *b, const char *type)
{
	size_t at = b->len;

	u32(b, 0);
	put(b, type, 4);
	return at;
}

static size_t fullbox_open(struct buf *b, const char *type, uint8_t version, uint32_t flags)
{
	size_t at = box_open(b, type);

	u32(b, (uint32_t)version << 24 | (flags & 0xffffff));
	return at;
}

static void box_close(struct buf *b, size_t at)
{
	uint32_t n = (uint32_t)(b->len - at);

	if (b->err)
		return;
	b->p[at] = n >> 24;
	b->p[at + 1] = n >> 16;
	b->p[at + 2] = n >> 8;
	b->p[at + 3] = n;
}

struct mp4mux *mp4mux_new(int width, int height, int fps)
{
	struct mp4mux *m = calloc(1, sizeof(*m));

	if (!m)
		return NULL;
	m->width = width;
	m->height = height;
	m->default_dur_us = fps > 0 ? 1000000 / fps : 166667;
	return m;
}

void mp4mux_free(struct mp4mux *m)
{
	if (!m)
		return;
	free(m->sps);
	free(m->pps);
	free(m->mdat);
	free(m->s);
	free(m);
}

int mp4mux_frames(const struct mp4mux *m)
{
	return m->n;
}

size_t mp4mux_bytes(const struct mp4mux *m)
{
	return m->mdat_len;
}

static int mdat_put(struct mp4mux *m, const uint8_t *d, size_t n)
{
	if (m->mdat_len + n > m->mdat_cap) {
		size_t c = m->mdat_cap ? m->mdat_cap * 2 : 65536;
		while (c < m->mdat_len + n)
			c *= 2;
		uint8_t *p = realloc(m->mdat, c);
		if (!p)
			return -1;
		m->mdat = p;
		m->mdat_cap = c;
	}
	memcpy(m->mdat + m->mdat_len, d, n);
	m->mdat_len += n;
	return 0;
}

static int keep_param(uint8_t **dst, size_t *dlen, const uint8_t *nal, size_t len)
{
	if (*dst && *dlen == len && !memcmp(*dst, nal, len))
		return 0;
	free(*dst);
	*dst = malloc(len);
	if (!*dst)
		return -1;
	memcpy(*dst, nal, len);
	*dlen = len;
	return 0;
}

/* Next Annex B start code at or after p; returns its position and the
 * length of the code (3 or 4) in *sc, or end if none. */
static const uint8_t *next_sc(const uint8_t *p, const uint8_t *end, int *sc)
{
	for (; p + 3 <= end; p++) {
		if (p[0] == 0 && p[1] == 0) {
			if (p[2] == 1) {
				*sc = 3;
				return p;
			}
			if (p + 4 <= end && p[2] == 0 && p[3] == 1) {
				*sc = 4;
				return p;
			}
		}
	}
	*sc = 0;
	return end;
}

int mp4mux_add(struct mp4mux *m, const uint8_t *au, size_t len, uint64_t pts_us)
{
	const uint8_t *end = au + len, *p;
	struct sample s = { .off = m->mdat_len, .pts_us = pts_us };
	int sc;

	p = next_sc(au, end, &sc);
	while (p < end) {
		const uint8_t *nal = p + sc, *q = next_sc(nal, end, &sc);
		const uint8_t *nend = q;
		size_t nlen;
		int type;

		/* trailing zero bytes belong to the next start code */
		while (nend > nal && nend[-1] == 0)
			nend--;
		nlen = (size_t)(nend - nal);
		p = q;
		if (!nlen)
			continue;
		type = nal[0] & 0x1f;
		if (type == 7) {		/* SPS: into avcC */
			if (keep_param(&m->sps, &m->sps_len, nal, nlen))
				return -1;
			continue;
		}
		if (type == 8) {		/* PPS: into avcC */
			if (keep_param(&m->pps, &m->pps_len, nal, nlen))
				return -1;
			continue;
		}
		if (type == 9)			/* access unit delimiter: not needed */
			continue;
		if (type == 5)
			s.key = 1;
		uint8_t l[4] = { nlen >> 24, nlen >> 16, nlen >> 8, nlen };
		if (mdat_put(m, l, 4) || mdat_put(m, nal, nlen))
			return -1;
	}
	s.len = m->mdat_len - s.off;
	if (!s.len)
		return 0;			/* parameter sets only */
	if (m->n == m->cap) {
		int c = m->cap ? m->cap * 2 : 64;
		struct sample *n = realloc(m->s, c * sizeof(*n));
		if (!n)
			return -1;
		m->s = n;
		m->cap = c;
	}
	m->s[m->n++] = s;
	return 1;
}

static uint32_t ticks(uint64_t us)
{
	return (uint32_t)((us * TIMESCALE + 500000) / 1000000);
}

static void matrix(struct buf *b)
{
	static const uint32_t mtx[9] = { 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000 };

	for (int i = 0; i < 9; i++)
		u32(b, mtx[i]);
}

static void write_moov(struct mp4mux *m, struct buf *b, uint32_t mdat_payload_off)
{
	uint64_t t0 = m->s[0].pts_us, dur_us;
	uint32_t *dur = malloc(m->n * sizeof(*dur));
	size_t moov, trak, mdia, minf, stbl, at;
	int keys = 0;

	if (!dur) {
		b->err = 1;
		return;
	}
	/* durations from timestamp differences; the last frame gets the
	 * previous frame's duration (or 1/fps for a one-frame clip) */
	for (int i = 0; i < m->n; i++) {
		uint64_t a = m->s[i].pts_us - t0, nx;
		if (i + 1 < m->n) {
			nx = m->s[i + 1].pts_us - t0;
			dur[i] = nx > a ? ticks(nx) - ticks(a) : ticks(m->default_dur_us);
		} else {
			dur[i] = i ? dur[i - 1] : ticks(m->default_dur_us);
		}
		if (!dur[i])
			dur[i] = 1;
		keys += m->s[i].key;
	}
	uint64_t total = 0;
	for (int i = 0; i < m->n; i++)
		total += dur[i];
	dur_us = total * 1000000 / TIMESCALE;

	moov = box_open(b, "moov");
	at = fullbox_open(b, "mvhd", 0, 0);
	u32(b, 0); u32(b, 0);				/* creation, modification */
	u32(b, MOVIE_TIMESCALE);
	u32(b, (uint32_t)(dur_us / 1000));
	u32(b, 0x10000); u16(b, 0x100); zeros(b, 10);	/* rate, volume, reserved */
	matrix(b);
	zeros(b, 24);					/* pre_defined */
	u32(b, 2);					/* next track id */
	box_close(b, at);

	trak = box_open(b, "trak");
	at = fullbox_open(b, "tkhd", 0, 3);		/* enabled, in movie */
	u32(b, 0); u32(b, 0); u32(b, 1); u32(b, 0);
	u32(b, (uint32_t)(dur_us / 1000));
	zeros(b, 8); u16(b, 0); u16(b, 0); u16(b, 0); u16(b, 0);
	matrix(b);
	u32(b, (uint32_t)m->width << 16);
	u32(b, (uint32_t)m->height << 16);
	box_close(b, at);

	mdia = box_open(b, "mdia");
	at = fullbox_open(b, "mdhd", 0, 0);
	u32(b, 0); u32(b, 0); u32(b, TIMESCALE); u32(b, (uint32_t)total);
	u16(b, 0x55c4);					/* language "und" */
	u16(b, 0);
	box_close(b, at);
	at = fullbox_open(b, "hdlr", 0, 0);
	u32(b, 0); put(b, "vide", 4); zeros(b, 12); put(b, "VideoHandler", 13);
	box_close(b, at);

	minf = box_open(b, "minf");
	at = fullbox_open(b, "vmhd", 0, 1);
	zeros(b, 8);
	box_close(b, at);
	size_t dinf = box_open(b, "dinf");
	size_t dref = fullbox_open(b, "dref", 0, 0);
	u32(b, 1);
	at = fullbox_open(b, "url ", 0, 1);
	box_close(b, at);
	box_close(b, dref);
	box_close(b, dinf);

	stbl = box_open(b, "stbl");
	size_t stsd = fullbox_open(b, "stsd", 0, 0);
	u32(b, 1);
	size_t avc1 = box_open(b, "avc1");
	zeros(b, 6); u16(b, 1);				/* reserved, data reference index */
	zeros(b, 16);					/* pre_defined, reserved */
	u16(b, (uint16_t)m->width); u16(b, (uint16_t)m->height);
	u32(b, 0x480000); u32(b, 0x480000);		/* 72 dpi */
	u32(b, 0); u16(b, 1);				/* reserved, frame count */
	zeros(b, 32);					/* compressor name */
	u16(b, 0x18); u16(b, 0xffff);			/* depth, pre_defined */
	size_t avcc = box_open(b, "avcC");
	u8(b, 1);
	u8(b, m->sps[1]); u8(b, m->sps[2]); u8(b, m->sps[3]);
	u8(b, 0xff);					/* 4-byte NAL lengths */
	u8(b, 0xe1); u16(b, (uint16_t)m->sps_len); put(b, m->sps, m->sps_len);
	u8(b, 1); u16(b, (uint16_t)m->pps_len); put(b, m->pps, m->pps_len);
	box_close(b, avcc);
	box_close(b, avc1);
	box_close(b, stsd);

	/* stts: run-length coded durations */
	at = fullbox_open(b, "stts", 0, 0);
	size_t cnt_at = b->len;
	u32(b, 0);
	uint32_t runs = 0;
	for (int i = 0; i < m->n;) {
		int j = i;
		while (j < m->n && dur[j] == dur[i])
			j++;
		u32(b, (uint32_t)(j - i));
		u32(b, dur[i]);
		runs++;
		i = j;
	}
	if (!b->err) {
		b->p[cnt_at] = runs >> 24; b->p[cnt_at + 1] = runs >> 16;
		b->p[cnt_at + 2] = runs >> 8; b->p[cnt_at + 3] = runs;
	}
	box_close(b, at);

	if (keys < m->n) {			/* all-sync tracks omit stss */
		at = fullbox_open(b, "stss", 0, 0);
		u32(b, (uint32_t)keys);
		for (int i = 0; i < m->n; i++)
			if (m->s[i].key)
				u32(b, (uint32_t)i + 1);
		box_close(b, at);
	}
	at = fullbox_open(b, "stsc", 0, 0);
	u32(b, 1); u32(b, 1); u32(b, (uint32_t)m->n); u32(b, 1);
	box_close(b, at);
	at = fullbox_open(b, "stsz", 0, 0);
	u32(b, 0); u32(b, (uint32_t)m->n);
	for (int i = 0; i < m->n; i++)
		u32(b, (uint32_t)m->s[i].len);
	box_close(b, at);
	at = fullbox_open(b, "stco", 0, 0);
	u32(b, 1); u32(b, mdat_payload_off);
	box_close(b, at);

	box_close(b, stbl);
	box_close(b, minf);
	box_close(b, mdia);
	box_close(b, trak);
	box_close(b, moov);
	free(dur);
}

int mp4mux_finish(struct mp4mux *m, uint8_t **out, size_t *len, uint32_t *duration_ms)
{
	struct buf head = { 0 }, probe = { 0 };
	size_t ftyp, moov_len, mdat_hdr;

	if (!m->n || !m->sps || !m->pps || m->sps_len < 4)
		return -1;
	ftyp = box_open(&head, "ftyp");
	put(&head, "isom", 4); u32(&head, 0x200);
	put(&head, "isomiso2avc1mp41", 16);
	box_close(&head, ftyp);

	/* the moov size does not depend on the chunk offset: measure, then write */
	write_moov(m, &probe, 0);
	moov_len = probe.len;
	if (probe.err) {
		free(probe.p);
		free(head.p);
		return -1;
	}
	free(probe.p);
	mdat_hdr = 8;
	write_moov(m, &head, (uint32_t)(head.len + moov_len + mdat_hdr));
	u32(&head, (uint32_t)(m->mdat_len + mdat_hdr));
	put(&head, "mdat", 4);
	put(&head, m->mdat, m->mdat_len);
	if (head.err) {
		free(head.p);
		return -1;
	}
	if (duration_ms) {
		uint64_t d = m->s[m->n - 1].pts_us - m->s[0].pts_us;
		d += m->n > 1 ? (m->s[m->n - 1].pts_us - m->s[m->n - 2].pts_us) : m->default_dur_us;
		*duration_ms = (uint32_t)(d / 1000);
	}
	*out = head.p;
	*len = head.len;
	return 0;
}
