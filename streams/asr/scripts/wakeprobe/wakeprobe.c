/* Wake-up latency probe: sleeps PERIOD_MS in a loop at normal priority (like
 * a UI or audio-control thread) and records how late each wake-up is. Runs
 * until SIGINT/SIGTERM or for SECONDS, then prints a summary.
 *
 *   wakeprobe [PERIOD_MS=10] [SECONDS=0 (until signalled)] [RAW_OUT]
 *
 * RAW_OUT, if given, gets one line per wake-up: CLOCK_MONOTONIC time in ms
 * and lateness in ms.
 * Output: n, median / p99 / max lateness in ms, and the count late by more
 * than 16 ms and 50 ms (one 60 Hz frame; a noticeable stall).
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static volatile sig_atomic_t stop;
static void on_signal(int s) { (void) s; stop = 1; }
static int cmp(const void * a, const void * b) {
    double x = *(const double *) a, y = *(const double *) b;
    return (x > y) - (x < y);
}
static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

int main(int argc, char ** argv) {
    const double period = argc > 1 ? atof(argv[1]) : 10.0;
    const double secs   = argc > 2 ? atof(argv[2]) : 0.0;
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    size_t   cap = 1 << 20, n = 0;
    double * late = malloc(cap * sizeof(double));
    double * when = malloc(cap * sizeof(double));
    const double t0 = now_ms();
    while (!stop && (secs <= 0 || now_ms() - t0 < secs * 1e3) && n < cap) {
        const double    want = now_ms() + period;
        struct timespec d    = { 0, (long) (period * 1e6) };
        nanosleep(&d, NULL);
        const double t = now_ms();
        when[n]        = t;
        late[n++]      = t - want;
    }
    if (argc > 3) {
        FILE * f = fopen(argv[3], "w");
        if (f != NULL) {
            for (size_t i = 0; i < n; ++i) {
                fprintf(f, "%.3f %.3f\n", when[i], late[i]);
            }
            fclose(f);
        }
    }
    qsort(late, n, sizeof(double), cmp);
    size_t over16 = 0, over50 = 0;
    for (size_t i = 0; i < n; ++i) {
        over16 += late[i] > 16.0;
        over50 += late[i] > 50.0;
    }
    if (n == 0) {
        printf("n 0\n");
        return 0;
    }
    printf("n %zu median_ms %.2f p99_ms %.2f max_ms %.2f over16 %zu over50 %zu\n", n, late[n / 2],
           late[(size_t) (n * 0.99)], late[n - 1], over16, over50);
    return 0;
}
