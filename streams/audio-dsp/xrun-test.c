// Force an xrun on a QDSP6 front-end PCM and try one way of getting it back.
//
//   xrun-test capture|playback DEVICE plain|recover|reopen [CYCLES]
//
// Opens DEVICE as straylight-listen does (48 kHz, S16_LE, 2 channels,
// 20 ms periods; capture buffer 160 ms, playback 80 ms), runs it for 1 s,
// then stops reading/writing for 0.5 s so the PCM overruns/underruns.
//   plain    no xrun: just the 1 s run (checks that the PCM works at all)
//   recover  snd_pcm_recover() (that is: prepare again, the stream restarts)
//   reopen   close the PCM and open it again with the same parameters
// then runs another second and reports how many frames moved. With CYCLES,
// starve/recover/run repeats that many times with idle times from 0.2 to
// 2 s. Playback
// writes silence only. Non-blocking with 1 s poll timeouts, so a stuck DSP
// shows up as "stall" instead of a hung process. XRUN_BLOCK=1 opens the PCM
// blocking and lets the first read start capture, as straylight-listen does.
//
// Build: clang --target=aarch64-linux-gnu --sysroot=SYSROOT -fuse-ld=lld \
//          -O2 -o build/xrun-test xrun-test.c -lasound -lm
#include <alsa/asoundlib.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RATE 48000
#define PERIOD 960

static int capture;
static const char *dev;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static snd_pcm_t *open_pcm(void) {
    snd_pcm_t *p;
    int e = snd_pcm_open(&p, dev, capture ? SND_PCM_STREAM_CAPTURE : SND_PCM_STREAM_PLAYBACK,
                         getenv("XRUN_BLOCK") ? 0 : SND_PCM_NONBLOCK);
    if (e < 0) {
        printf("open %s: %s\n", dev, snd_strerror(e));
        return NULL;
    }
    snd_pcm_hw_params_t *hw;
    snd_pcm_hw_params_alloca(&hw);
    snd_pcm_hw_params_any(p, hw);
    snd_pcm_hw_params_set_access(p, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
    snd_pcm_hw_params_set_format(p, hw, SND_PCM_FORMAT_S16_LE);
    snd_pcm_hw_params_set_channels(p, hw, 2);
    unsigned rate = RATE;
    snd_pcm_hw_params_set_rate_near(p, hw, &rate, NULL);
    snd_pcm_uframes_t per = PERIOD, buf = capture ? PERIOD * 8 : PERIOD * 4;
    snd_pcm_hw_params_set_period_size_near(p, hw, &per, NULL);
    snd_pcm_hw_params_set_buffer_size_near(p, hw, &buf);
    if ((e = snd_pcm_hw_params(p, hw)) < 0) { // prepares, as in alsa-lib
        printf("hw_params: %s\n", snd_strerror(e));
        snd_pcm_close(p);
        return NULL;
    }
    if (!capture) {
        snd_pcm_sw_params_t *sw;
        snd_pcm_sw_params_alloca(&sw);
        snd_pcm_sw_params_current(p, sw);
        snd_pcm_sw_params_set_start_threshold(p, sw, PERIOD);
        snd_pcm_sw_params(p, sw);
    }
    if ((e = snd_pcm_prepare(p)) < 0) { // the second prepare straylight-listen does
        printf("prepare: %s\n", snd_strerror(e));
        snd_pcm_close(p);
        return NULL;
    }
    printf("opened %s: rate %u period %lu buffer %lu\n", dev, rate, per, buf);
    return p;
}

// Move frames for `secs`; returns frames moved, prints level (capture),
// stalls and errors. Stops at the first error unless `xrun_ok`.
static long run(snd_pcm_t *p, double secs, const char *what) {
    static short b[PERIOD * 2];
    long frames = 0;
    int stalls = 0, errs = 0;
    double sum = 0, peak = 0, t0 = now();
    if (!capture)
        memset(b, 0, sizeof b);
    else if (!getenv("XRUN_BLOCK") && snd_pcm_state(p) == SND_PCM_STATE_PREPARED) {
        int e = snd_pcm_start(p);
        if (e < 0)
            printf("%s: start: %s\n", what, snd_strerror(e));
    }
    while (now() - t0 < secs) {
        // Blocking: no poll first (a capture PCM in PREPARED never wakes a
        // poll; the read starts it). The kernel times a stuck read out at 10 s.
        int w = getenv("XRUN_BLOCK") ? 1 : snd_pcm_wait(p, 1000);
        if (w == 0) {
            stalls++;
            printf("%s: stall (no period in 1 s), state %s\n", what, snd_pcm_state_name(snd_pcm_state(p)));
            if (stalls >= 2)
                break;
            continue;
        }
        snd_pcm_sframes_t n = capture ? snd_pcm_readi(p, b, PERIOD) : snd_pcm_writei(p, b, PERIOD);
        if (n == -EAGAIN)
            continue;
        if (n < 0) {
            errs++;
            printf("%s: %s: %s, state %s\n", what, capture ? "readi" : "writei", snd_strerror(n),
                   snd_pcm_state_name(snd_pcm_state(p)));
            break;
        }
        frames += n;
        if (capture)
            for (long i = 0; i < n * 2; i++) {
                double v = b[i] / 32768.0;
                sum += v * v;
                if (fabs(v) > peak)
                    peak = fabs(v);
            }
    }
    double el = now() - t0;
    printf("%s: %ld frames in %.2f s (%.0f%% of real time), %d stalls, %d errors", what, frames, el,
           100.0 * frames / (RATE * el), stalls, errs);
    if (capture && frames)
        printf(", rms %.1f dBFS, peak %.1f dBFS", 10 * log10(sum / (frames * 2) + 1e-20), 20 * log10(peak + 1e-10));
    printf("\n");
    return frames;
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) {
        fprintf(stderr, "usage: xrun-test capture|playback DEVICE plain|recover|reopen [CYCLES]\n");
        return 2;
    }
    capture = !strcmp(argv[1], "capture");
    dev = argv[2];
    const char *mode = argv[3];
    setvbuf(stdout, NULL, _IOLBF, 0);
    snd_pcm_t *p = open_pcm();
    if (!p)
        return 1;
    long f = run(p, 1.0, "before");
    if (!strcmp(mode, "plain")) {
        snd_pcm_close(p);
        return f > RATE / 2 ? 0 : 1;
    }
    int cycles = argc == 5 ? atoi(argv[4]) : 1, good = 0;
    for (int c = 0; c < cycles; c++) {
        // Starve it: 0.5 s with no reads/writes (buffer is 160/80 ms); with
        // several cycles, 0.2 to 2 s.
        long ms = cycles == 1 ? 500 : 200 + (c * 397) % 1801;
        struct timespec ts = {ms / 1000, (ms % 1000) * 1000000};
        nanosleep(&ts, NULL);
        if (cycles > 1)
            printf("-- cycle %d, idle %ld ms\n", c + 1, ms);
        printf("state after %ld ms idle: %s\n", ms, snd_pcm_state_name(snd_pcm_state(p)));
        if (!strcmp(mode, "recover")) {
            int e = snd_pcm_recover(p, -EPIPE, 0);
            printf("snd_pcm_recover: %s, state %s\n", e < 0 ? snd_strerror(e) : "ok",
                   snd_pcm_state_name(snd_pcm_state(p)));
            if (!capture) {
                // straylight-listen's player: if recover failed, prepare.
                if (e < 0) {
                    e = snd_pcm_prepare(p);
                    printf("snd_pcm_prepare: %s\n", e < 0 ? snd_strerror(e) : "ok");
                }
            }
        } else {
            double t = now();
            snd_pcm_close(p);
            p = open_pcm();
            if (!p)
                return 1;
            printf("reopen took %.0f ms\n", (now() - t) * 1000);
        }
        f = run(p, cycles == 1 ? 1.0 : 0.5, "after");
        if (f > RATE / 4 * (cycles == 1 ? 2 : 1))
            good++;
    }
    if (cycles > 1)
        printf("%d of %d cycles moved audio\n", good, cycles);
    double t = now();
    snd_pcm_close(p);
    printf("close took %.0f ms\n", (now() - t) * 1000);
    return good == cycles ? 0 : 1;
}
