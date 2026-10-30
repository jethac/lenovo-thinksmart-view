// tsv-idle-rotate: the ai& idle screen, kept upright by the accelerometer.
//
// Draws the wordmark (white on black, red accent stripe, 520 px wide, centred,
// exactly the static idle frame at 0 degrees) through DRM/KMS with two dumb
// buffers and vblank-synced page flips, rotated so that it stays level while
// the tablet is turned in the screen plane.
//
//   tilt   theta = atan2(a_x, -a_y)      tablet's clockwise turn as seen by the
//                                        viewer (0 = native portrait, upright)
//   draw   the logo turned by -theta on the panel (anticlockwise when the
//          tablet is turned clockwise), so it stays level for the viewer.
//
// Smoothing: the in-plane gravity vector is low-pass filtered (one pole,
// tau 0.12 s), the displayed angle follows the filtered angle through a
// critically damped spring (eased start and stop, no overshoot), and nothing
// is drawn until the target is more than DEADBAND away from what is shown.
// With less than FLAT_MS2 of in-plane gravity (tablet lying flat) the last
// angle is held.
//
// Cost: when still, it sleeps on the accelerometer's motion interrupt and reads
// x and y once a second as a safety net, and it holds no DRM master. While turning, it samples at 25 Hz and
// renders one frame per vblank; it holds DRM master only while animating, and
// never while plymouthd runs.
//
// It never touches fbcon, the backlight or a tty: tsv-idle-screen does that,
// and draws the static fallback on /dev/fb0 before this starts. Any setup
// failure exits 0 and leaves that static frame up.
//
// Usage:
//   tsv-idle-rotate                   run (systemd: tsv-idle-screen.service)
//   tsv-idle-rotate --probe           print the sensor reading and angle
//   tsv-idle-rotate --render DEG FILE render one 800x1280 XRGB8888 frame (tilt
//                                     DEG) to FILE, no device needed
// Testing (environment):
//   TSV_ROTATE_FAKE=FILE   read "ax ay az" (m/s^2) from FILE instead of the IIO
//                          device, re-read at every sample
//   TSV_ROTATE_SPIN=DEG_S  ignore the sensor; target turns at DEG_S deg/s
//   TSV_ROTATE_SLOPE=N     motion interrupt threshold (raw, default 2)
//   TSV_ROTATE_CARD, TSV_ROTATE_IIO  device paths
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#include <drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <linux/iio/events.h>

// ---------------------------------------------------------------- logo
// LOGO_FILE: raw 524x175 B,G,R,X little-endian, the wordmark already composited
// on black (i.e. premultiplied), with a 2 px black border. It is the crop
// +138+552 of the static idle frame (render-logo.sh).
#define LW 524
#define LH 175
#define LOGO_X0 138 /* crop origin in the 800x1280 static frame */
#define LOGO_Y0 552
#define STR_(x) #x
#define STR(x) STR_(x)
__asm__(".section .rodata\n"
        ".balign 16\n"
        ".global tsv_logo\n"
        "tsv_logo:\n"
        ".incbin \"" LOGO_FILE "\"\n"
        ".global tsv_logo_end\n"
        "tsv_logo_end:\n"
        ".previous\n");
extern const uint32_t tsv_logo[];
extern const unsigned char tsv_logo_end[];

// ---------------------------------------------------------------- tuning
#define TAU_S 0.12          /* gravity low-pass time constant */
#define FLAT_MS2 3.0        /* below this in-plane gravity: hold the angle */
#define UNFLAT_MS2 3.5      /* ... until it is back above this */
#define DEADBAND_DEG 0.75   /* start moving only past this error */
#define SETTLE_DEG 0.03     /* stop when this close ... */
#define SETTLE_VEL 0.5      /* ... and slower than this (deg/s) */
#define OMEGA 7.0           /* spring rate (rad/s): ~1.2 s for 90 degrees */
#define FAST_NS 40000000LL  /* 25 Hz sampling while moving */
#define SLOW_NS 200000000LL /* 5 Hz when still, without the motion interrupt */
#define SLOW_EV_NS 1000000000LL /* 1 Hz safety poll when still, with it */
#define STILL_NS 3000000000LL

static const char *prog = "tsv-idle-rotate";
static void logm(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "%s: ", prog);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static int64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static double wrap180(double d)
{
    d = fmod(d + 180.0, 360.0);
    if (d < 0)
        d += 360.0;
    return d - 180.0;
}

// ---------------------------------------------------------------- render
typedef struct {
    int x0, y0, x1, y1; // half-open; empty when x0 >= x1
} rect_t;

static inline uint32_t lerp_px(uint32_t a, uint32_t b, uint32_t f) // f 0..255
{
    uint32_t g = 256 - f;
    uint32_t rb = ((a & 0xff00ffu) * g + (b & 0xff00ffu) * f) >> 8;
    uint32_t gg = ((a & 0x00ff00u) * g + (b & 0x00ff00u) * f) >> 8;
    return (rb & 0xff00ffu) | (gg & 0x00ff00u);
}

// Draw the logo turned by -tilt (tilt in degrees, clockwise positive) into an
// XRGB8888 frame of w x h with pitch in pixels. *drawn is the rectangle this
// buffer last drew into; it is cleared to black first and then updated.
static void render(uint32_t *fb, int pitch, int w, int h, double tilt_deg, rect_t *drawn)
{
    for (int y = drawn->y0; y < drawn->y1; y++)
        memset(fb + (size_t)y * pitch + drawn->x0, 0, (size_t)(drawn->x1 - drawn->x0) * 4);

    // Centre: where the static frame has it (+140+554, 520x171 on 800x1280).
    double cx = (double)((w - 520) / 2) + 260.0, cy = (double)((h - 171) / 2) + 85.5;
    double scx = 260.0 + 2, scy = 85.5 + 2; // the same point in logo coordinates
    double t = tilt_deg * M_PI / 180.0, c = cos(t), s = sin(t);
    if (fabs(tilt_deg - 360.0 * round(tilt_deg / 360.0)) < 1e-9)
        c = 1, s = 0; // exact copy of the static frame at 0

    // Screen -> logo (sampling): q = R(t) (p - C) + Cs with R(t) = [c -s; s c].
    // Logo -> screen (bounding box): p = R(-t) (q - Cs) + C.
    double xs[4] = {0, LW, 0, LW}, ys[4] = {0, 0, LH, LH};
    double bx0 = 1e9, by0 = 1e9, bx1 = -1e9, by1 = -1e9;
    for (int i = 0; i < 4; i++) {
        double qx = xs[i] - scx, qy = ys[i] - scy;
        double px = c * qx + s * qy + cx, py = -s * qx + c * qy + cy;
        bx0 = fmin(bx0, px), bx1 = fmax(bx1, px), by0 = fmin(by0, py), by1 = fmax(by1, py);
    }
    rect_t r = {(int)floor(bx0) - 1, (int)floor(by0) - 1, (int)ceil(bx1) + 1, (int)ceil(by1) + 1};
    if (r.x0 < 0) r.x0 = 0;
    if (r.y0 < 0) r.y0 = 0;
    if (r.x1 > w) r.x1 = w;
    if (r.y1 > h) r.y1 = h;

    // 16.16 fixed point; per screen x step: du = c, dv = s.
    const int32_t du = (int32_t)lround(c * 65536.0), dv = (int32_t)lround(s * 65536.0);
    for (int y = r.y0; y < r.y1; y++) {
        double px = r.x0 + 0.5 - cx, py = y + 0.5 - cy;
        // -0.5: sample at pixel centres of the logo
        int32_t u = (int32_t)lround((c * px - s * py + scx - 0.5) * 65536.0);
        int32_t v = (int32_t)lround((s * px + c * py + scy - 0.5) * 65536.0);
        uint32_t *row = fb + (size_t)y * pitch;
        for (int x = r.x0; x < r.x1; x++, u += du, v += dv) {
            int32_t iu = u >> 16, iv = v >> 16;
            uint32_t o = 0;
            if ((uint32_t)iu < LW - 1 && (uint32_t)iv < LH - 1) {
                const uint32_t *p = tsv_logo + iv * LW + iu;
                uint32_t a = p[0], b = p[1], d = p[LW], e = p[LW + 1];
                if ((a | b | d | e) & 0xffffffu) {
                    uint32_t fu = (u >> 8) & 0xff, fv = (v >> 8) & 0xff;
                    o = lerp_px(lerp_px(a, b, fu), lerp_px(d, e, fu), fv);
                }
            }
            row[x] = o;
        }
    }
    *drawn = r;
}

// ---------------------------------------------------------------- sensor
// On this board the BMA253 sits on a bit-banged i2c-gpio bus, so every
// register read busy-waits in the kernel (about 0.7 ms of CPU per sysfs read).
// Hence: only x and y are read (z does not enter the in-plane angle), and when
// still the chip's own slope ("any-motion", IIO roc) interrupt wakes us, with
// a slow safety poll for turns too gentle to trip it.
typedef struct {
    int fd[3];
    bool need_z;
    double scale;
    double m[9]; // mount matrix
    const char *fake;
    double spin; // deg/s, 0 = off
    int64_t t0;
    char dir[256];
    int evfd;          // IIO event fd, -1 if none
    bool ev_on;
    char odr_saved[32]; // in_accel_sampling_frequency to restore, "" = untouched
} accel_t;

static int read_long(int fd, long *out)
{
    char b[32];
    ssize_t n = pread(fd, b, sizeof b - 1, 0);
    if (n <= 0)
        return -1;
    b[n] = 0;
    char *e;
    *out = strtol(b, &e, 10);
    return e == b ? -1 : 0;
}

static bool read_file(const char *path, char *buf, size_t len)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    if (n <= 0)
        return false;
    buf[n] = 0;
    return true;
}

static bool write_attr(const char *dir, const char *name, const char *val)
{
    char p[384];
    snprintf(p, sizeof p, "%s/%s", dir, name);
    int fd = open(p, O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    bool ok = write(fd, val, strlen(val)) == (ssize_t)strlen(val);
    close(fd);
    return ok;
}

static bool find_iio(char *out, size_t len)
{
    const char *env = getenv("TSV_ROTATE_IIO");
    if (env) {
        snprintf(out, len, "%s", env);
        return true;
    }
    DIR *d = opendir("/sys/bus/iio/devices");
    if (!d)
        return false;
    struct dirent *e;
    bool found = false;
    while (!found && (e = readdir(d))) {
        if (strncmp(e->d_name, "iio:device", 10))
            continue;
        char p[300];
        snprintf(p, sizeof p, "/sys/bus/iio/devices/%s/in_accel_x_raw", e->d_name);
        if (access(p, R_OK) == 0) {
            snprintf(out, len, "/sys/bus/iio/devices/%s", e->d_name);
            found = true;
        }
    }
    closedir(d);
    return found;
}

// Motion interrupt on x and y (slope over successive samples). Off while we
// poll fast anyway: each interrupt costs two more bit-banged register reads.
static void accel_events(accel_t *a, bool on)
{
    if (a->evfd < 0 || a->ev_on == on)
        return;
    const char *v = on ? "1" : "0";
    if (!write_attr(a->dir, "events/in_accel_x_roc_either_en", v) ||
        !write_attr(a->dir, "events/in_accel_y_roc_either_en", v)) {
        logm("cannot %s motion events (%s); polling only", on ? "enable" : "disable", strerror(errno));
        close(a->evfd);
        a->evfd = -1;
        return;
    }
    a->ev_on = on;
}

// Returns true if a motion event was pending.
static bool accel_drain(accel_t *a)
{
    bool any = false;
    struct iio_event_data ev[8];
    while (a->evfd >= 0 && read(a->evfd, ev, sizeof ev) > 0)
        any = true;
    return any;
}

static void accel_setup_events(accel_t *a)
{
    a->evfd = -1;
    char p[320], buf[64];
    const char *base = strrchr(a->dir, '/');
    snprintf(p, sizeof p, "/dev/%s", base ? base + 1 : a->dir);
    int dfd = open(p, O_RDONLY | O_CLOEXEC);
    if (dfd < 0) {
        logm("%s: %s; polling only", p, strerror(errno));
        return;
    }
    int efd = -1;
    if (ioctl(dfd, IIO_GET_EVENT_FD_IOCTL, &efd) < 0 || efd < 0) {
        logm("%s: no event fd (%s); polling only", p, strerror(errno));
        close(dfd);
        return;
    }
    close(dfd); // the event fd stays valid on its own
    fcntl(efd, F_SETFL, O_NONBLOCK);
    fcntl(efd, F_SETFD, FD_CLOEXEC);
    a->evfd = efd;
    // 31.25 Hz output rate (15.6 Hz bandwidth): less noise, and a slow turn
    // gives a larger slope per sample, so the motion interrupt sees it.
    snprintf(p, sizeof p, "%s/in_accel_sampling_frequency", a->dir);
    if (read_file(p, buf, sizeof buf)) {
        buf[strcspn(buf, "\n")] = 0;
        if (atof(buf) != 31.26 && write_attr(a->dir, "in_accel_sampling_frequency", "31.26"))
            snprintf(a->odr_saved, sizeof a->odr_saved, "%s", buf);
    }
    // Threshold 2 (raw slope register: 2 x 7.8 mg at +-4 g), over 2 samples.
    // The driver refuses these while the event is enabled (a crashed run may
    // have left it on), so switch it off first.
    const char *slope = getenv("TSV_ROTATE_SLOPE");
    if (!slope)
        slope = "2";
    for (int i = 0; i < 2; i++) {
        char n[64];
        snprintf(n, sizeof n, "events/in_accel_%c_roc_either_en", "xy"[i]);
        write_attr(a->dir, n, "0");
        snprintf(n, sizeof n, "events/in_accel_%c_roc_either_value", "xy"[i]);
        if (!write_attr(a->dir, n, slope))
            logm("cannot set %s: %s", n, strerror(errno));
        snprintf(n, sizeof n, "events/in_accel_%c_roc_either_period", "xy"[i]);
        write_attr(a->dir, n, "1");
    }
}

static bool accel_open(accel_t *a)
{
    memset(a, 0, sizeof *a);
    a->fd[0] = a->fd[1] = a->fd[2] = -1;
    a->evfd = -1;
    a->m[0] = a->m[4] = a->m[8] = 1;
    a->fake = getenv("TSV_ROTATE_FAKE");
    const char *spin = getenv("TSV_ROTATE_SPIN");
    if (spin) {
        a->spin = atof(spin);
        a->t0 = now_ns();
        logm("test mode: target spins at %.1f deg/s", a->spin);
        return true;
    }
    if (a->fake) {
        logm("test mode: accelerometer from %s", a->fake);
        return true;
    }
    char p[320], buf[256];
    if (!find_iio(a->dir, sizeof a->dir)) {
        logm("no IIO accelerometer");
        return false;
    }
    snprintf(p, sizeof p, "%s/in_accel_scale", a->dir);
    a->scale = read_file(p, buf, sizeof buf) ? atof(buf) : 0;
    if (!(a->scale > 0)) {
        logm("%s: no scale", p);
        return false;
    }
    snprintf(p, sizeof p, "%s/in_mount_matrix", a->dir);
    if (read_file(p, buf, sizeof buf)) {
        double m[9];
        if (sscanf(buf, "%lf , %lf , %lf ; %lf , %lf , %lf ; %lf , %lf , %lf", &m[0], &m[1], &m[2], &m[3],
                   &m[4], &m[5], &m[6], &m[7], &m[8]) == 9)
            memcpy(a->m, m, sizeof m);
    }
    a->need_z = a->m[2] != 0 || a->m[5] != 0;
    for (int i = 0; i < (a->need_z ? 3 : 2); i++) {
        snprintf(p, sizeof p, "%s/in_accel_%c_raw", a->dir, "xyz"[i]);
        if ((a->fd[i] = open(p, O_RDONLY | O_CLOEXEC)) < 0) {
            logm("%s: %s", p, strerror(errno));
            return false;
        }
    }
    snprintf(p, sizeof p, "%s/name", a->dir);
    if (!read_file(p, buf, sizeof buf))
        strcpy(buf, "?\n");
    buf[strcspn(buf, "\n")] = 0;
    accel_setup_events(a);
    logm("accelerometer %s (%s), scale %g, motion interrupt %s", a->dir, buf, a->scale,
         a->evfd >= 0 ? "on" : "unavailable");
    return true;
}

static void accel_close(accel_t *a)
{
    accel_events(a, false);
    if (a->odr_saved[0])
        write_attr(a->dir, "in_accel_sampling_frequency", a->odr_saved);
    if (a->evfd >= 0)
        close(a->evfd);
}

// In-plane gravity in m/s^2 (g[0] = x, g[1] = y), device frame after the mount matrix.
static bool accel_read(accel_t *a, double g[2])
{
    if (a->spin) {
        double t = (now_ns() - a->t0) / 1e9 * a->spin * M_PI / 180.0;
        g[0] = 9.5 * sin(t), g[1] = -9.5 * cos(t);
        return true;
    }
    double r[3] = {0};
    if (a->fake) {
        char buf[128];
        if (!read_file(a->fake, buf, sizeof buf) || sscanf(buf, "%lf %lf %lf", &r[0], &r[1], &r[2]) < 2)
            return false;
    } else {
        for (int i = 0; i < (a->need_z ? 3 : 2); i++) {
            long v;
            if (read_long(a->fd[i], &v))
                return false;
            r[i] = v * a->scale;
        }
    }
    for (int i = 0; i < 2; i++)
        g[i] = a->m[3 * i] * r[0] + a->m[3 * i + 1] * r[1] + a->m[3 * i + 2] * r[2];
    return true;
}

// ---------------------------------------------------------------- kms
typedef struct {
    uint32_t handle, fb, pitch;
    uint64_t size;
    uint32_t *map;
    rect_t drawn;
} buf_t;

typedef struct {
    int fd;
    uint32_t conn, crtc, saved_fb;
    drmModeModeInfo mode;
    int w, h;
    buf_t b[2];
    int front;
    bool flip_pending, master, shown;
} kms_t;

static bool plymouth_running(void)
{
    char buf[32];
    if (!read_file("/run/plymouth/pid", buf, sizeof buf))
        return false;
    pid_t pid = (pid_t)atol(buf);
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

static bool kms_acquire(kms_t *k)
{
    if (k->master)
        return true;
    if (plymouth_running())
        return false;
    if (drmSetMaster(k->fd)) {
        return false;
    }
    k->master = true;
    return true;
}

static void kms_release(kms_t *k)
{
    if (k->master && !k->flip_pending) {
        drmDropMaster(k->fd);
        k->master = false;
    }
}

static bool buf_create(kms_t *k, buf_t *b)
{
    struct drm_mode_create_dumb cd = {.width = (uint32_t)k->w, .height = (uint32_t)k->h, .bpp = 32};
    if (drmIoctl(k->fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        logm("CREATE_DUMB: %s", strerror(errno));
        return false;
    }
    b->handle = cd.handle, b->pitch = cd.pitch, b->size = cd.size;
    uint32_t h[4] = {b->handle}, p[4] = {b->pitch}, o[4] = {0};
    if (drmModeAddFB2(k->fd, k->w, k->h, DRM_FORMAT_XRGB8888, h, p, o, &b->fb, 0)) {
        logm("AddFB2: %s", strerror(errno));
        return false;
    }
    struct drm_mode_map_dumb md = {.handle = b->handle};
    if (drmIoctl(k->fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
        logm("MAP_DUMB: %s", strerror(errno));
        return false;
    }
    b->map = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, k->fd, md.offset);
    if (b->map == MAP_FAILED) {
        b->map = NULL;
        logm("mmap: %s", strerror(errno));
        return false;
    }
    memset(b->map, 0, b->size);
    b->drawn = (rect_t){0, 0, 0, 0};
    return true;
}

static void kms_close(kms_t *k)
{
    if (k->fd < 0)
        return;
    // Put fbdev's framebuffer (the static frame, or the console after
    // tsv-idle-screen stop) back on the CRTC before our buffers go away.
    if (k->shown && k->saved_fb && (k->master || kms_acquire(k))) {
        if (drmModeSetCrtc(k->fd, k->crtc, k->saved_fb, 0, 0, &k->conn, 1, &k->mode))
            logm("could not restore fb %u: %s", k->saved_fb, strerror(errno));
    }
    for (int i = 0; i < 2; i++) {
        buf_t *b = &k->b[i];
        if (b->map)
            munmap(b->map, b->size);
        if (b->fb)
            drmModeRmFB(k->fd, b->fb);
        if (b->handle) {
            struct drm_mode_destroy_dumb dd = {.handle = b->handle};
            drmIoctl(k->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
        }
    }
    if (k->master)
        drmDropMaster(k->fd);
    close(k->fd);
    k->fd = -1;
}

static bool kms_open(kms_t *k)
{
    memset(k, 0, sizeof *k);
    const char *card = getenv("TSV_ROTATE_CARD");
    if (!card)
        card = "/dev/dri/card0";
    k->fd = open(card, O_RDWR | O_CLOEXEC);
    if (k->fd < 0) {
        logm("%s: %s", card, strerror(errno));
        return false;
    }
    uint64_t dumb = 0;
    if (drmGetCap(k->fd, DRM_CAP_DUMB_BUFFER, &dumb) || !dumb) {
        logm("%s: no dumb buffers", card);
        return false;
    }
    drmModeRes *res = drmModeGetResources(k->fd);
    if (!res) {
        logm("GetResources: %s", strerror(errno));
        return false;
    }
    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors && !conn; i++) {
        drmModeConnector *c = drmModeGetConnector(k->fd, res->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0)
            conn = c;
        else
            drmModeFreeConnector(c);
    }
    if (!conn) {
        logm("no connected connector");
        drmModeFreeResources(res);
        return false;
    }
    k->conn = conn->connector_id;
    k->mode = conn->modes[0];
    for (int i = 0; i < conn->count_modes; i++)
        if (conn->modes[i].type & DRM_MODE_TYPE_PREFERRED) {
            k->mode = conn->modes[i];
            break;
        }
    k->w = k->mode.hdisplay, k->h = k->mode.vdisplay;

    // Prefer the CRTC already driving this connector (fbdev set it up).
    uint32_t crtc = 0;
    drmModeEncoder *enc = conn->encoder_id ? drmModeGetEncoder(k->fd, conn->encoder_id) : NULL;
    if (enc && enc->crtc_id)
        crtc = enc->crtc_id;
    for (int e = 0; !crtc && e < conn->count_encoders; e++) {
        drmModeEncoder *en = drmModeGetEncoder(k->fd, conn->encoders[e]);
        for (int i = 0; en && !crtc && i < res->count_crtcs; i++)
            if (en->possible_crtcs & (1u << i))
                crtc = res->crtcs[i];
        drmModeFreeEncoder(en);
    }
    drmModeFreeEncoder(enc);
    if (!crtc) {
        logm("no CRTC for connector %u", k->conn);
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        return false;
    }
    k->crtc = crtc;
    drmModeCrtc *cur = drmModeGetCrtc(k->fd, crtc);
    if (cur) {
        k->saved_fb = cur->buffer_id;
        if (cur->mode_valid && cur->mode.hdisplay == k->mode.hdisplay && cur->mode.vdisplay == k->mode.vdisplay)
            k->mode = cur->mode; // keep exactly what is running: no modeset
        drmModeFreeCrtc(cur);
    }
    logm("%s: connector %u (%s-%u), crtc %u, %dx%d@%u, fbdev fb %u", card, k->conn,
         drmModeGetConnectorTypeName(conn->connector_type) ?: "?", conn->connector_type_id, crtc, k->w, k->h,
         k->mode.vrefresh, k->saved_fb);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    for (int i = 0; i < 2; i++)
        if (!buf_create(k, &k->b[i]))
            return false;
    return true;
}

static void on_flip(int fd, unsigned seq, unsigned sec, unsigned usec, void *data)
{
    (void)fd, (void)seq, (void)sec, (void)usec;
    kms_t *k = data;
    k->flip_pending = false;
    k->front ^= 1;
}

// Render tilt into the back buffer and queue it for the next vblank (or set
// it directly the first time). Needs DRM master.
static bool kms_present(kms_t *k, double tilt)
{
    if (!kms_acquire(k))
        return false;
    int back = k->shown ? k->front ^ 1 : k->front;
    buf_t *b = &k->b[back];
    render(b->map, (int)(b->pitch / 4), k->w, k->h, tilt, &b->drawn);
    if (!k->shown) {
        if (drmModeSetCrtc(k->fd, k->crtc, b->fb, 0, 0, &k->conn, 1, &k->mode)) {
            logm("SetCrtc: %s", strerror(errno));
            return false;
        }
        k->shown = true;
        return true;
    }
    if (drmModePageFlip(k->fd, k->crtc, b->fb, DRM_MODE_PAGE_FLIP_EVENT, k)) {
        logm("PageFlip: %s", strerror(errno));
        return false;
    }
    k->flip_pending = true;
    return true;
}

// ---------------------------------------------------------------- modes
static int do_render(const char *deg, const char *out)
{
    size_t n = (size_t)800 * 1280;
    uint32_t *fb = calloc(n, 4);
    rect_t r = {0};
    if (!fb)
        return 1;
    render(fb, 800, 800, 1280, atof(deg), &r);
    FILE *f = fopen(out, "wb");
    if (!f || fwrite(fb, 4, n, f) != n || fclose(f)) {
        perror(out);
        return 1;
    }
    printf("tilt %s deg: drew %d,%d-%d,%d\n", deg, r.x0, r.y0, r.x1, r.y1);
    return 0;
}

static int do_probe(void)
{
    accel_t a;
    if (!accel_open(&a))
        return 1;
    double s[2] = {0}, g[2];
    accel_read(&a, g); // the first read after the chip wakes can be stale
    usleep(100000);
    for (int i = 0; i < 10; i++) {
        if (!accel_read(&a, g))
            return 1;
        for (int j = 0; j < 2; j++)
            s[j] += g[j] / 10;
        usleep(35000);
    }
    accel_close(&a);
    printf("gravity x %+.2f y %+.2f m/s^2, in-plane %.2f, tilt %+.1f deg clockwise -> logo drawn at "
           "%+.1f deg (clockwise on the panel)\n",
           s[0], s[1], hypot(s[0], s[1]), atan2(s[0], -s[1]) * 180 / M_PI, -atan2(s[0], -s[1]) * 180 / M_PI);
    return 0;
}

static void set_timer(int tfd, int64_t period)
{
    struct itimerspec it = {{period / 1000000000LL, period % 1000000000LL},
                            {period / 1000000000LL, period % 1000000000LL}};
    timerfd_settime(tfd, 0, &it, NULL);
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "--render"))
        return do_render(argv[2], argv[3]);
    if (argc == 2 && !strcmp(argv[1], "--probe"))
        return do_probe();
    if (argc != 1) {
        fprintf(stderr, "usage: %s [--probe | --render DEG FILE]\n", argv[0]);
        return 2;
    }
    if ((size_t)(tsv_logo_end - (const unsigned char *)tsv_logo) != (size_t)LW * LH * 4) {
        logm("embedded logo has the wrong size");
        return 0;
    }
    setvbuf(stderr, NULL, _IOLBF, 0);

    accel_t acc;
    if (!accel_open(&acc)) {
        logm("no accelerometer; leaving the static frame");
        return 0;
    }
    // Initial gravity: mean of a few samples, after one throwaway read (the
    // chip may just have woken from runtime suspend) and a settling pause.
    double g[2], gx = 0, gy = 0;
    int ok = 0;
    accel_read(&acc, g);
    usleep(100000);
    for (int i = 0; i < 4; i++) {
        if (accel_read(&acc, g))
            gx += g[0], gy += g[1], ok++;
        usleep(35000);
    }
    if (!ok) {
        logm("accelerometer unreadable; leaving the static frame");
        accel_close(&acc);
        return 0;
    }
    gx /= ok, gy /= ok;
    bool flat = hypot(gx, gy) < FLAT_MS2;
    double target = flat ? 0.0 : atan2(gx, -gy) * 180 / M_PI;
    double shown = target, vel = 0;

    sigset_t ss;
    sigemptyset(&ss);
    sigaddset(&ss, SIGTERM);
    sigaddset(&ss, SIGINT);
    sigaddset(&ss, SIGHUP);
    sigprocmask(SIG_BLOCK, &ss, NULL);
    int sfd = signalfd(-1, &ss, SFD_CLOEXEC);

    // Plymouth holds DRM master until it quits; wait for it (the unit is
    // ordered after plymouth-quit, so this is only a safety net).
    for (int i = 0; plymouth_running(); i++) {
        if (i == 0)
            logm("plymouthd is running; waiting");
        struct signalfd_siginfo si;
        struct pollfd p = {sfd, POLLIN, 0};
        if (poll(&p, 1, 500) > 0 && read(sfd, &si, sizeof si) > 0)
            return 0;
    }

    kms_t k;
    if (!kms_open(&k)) {
        logm("KMS unavailable; leaving the static frame on fb0");
        kms_close(&k);
        accel_close(&acc);
        return 0;
    }
    if (!kms_present(&k, shown)) {
        logm("could not show the first frame (DRM master busy?); leaving the static frame");
        kms_close(&k);
        accel_close(&acc);
        return 0;
    }
    kms_release(&k);
    logm("showing the logo at tilt %+.1f deg%s", shown, flat ? " (flat: upright)" : "");

    int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    // Still: the motion interrupt wakes us; poll only as a safety net.
    const int64_t slow_ns = acc.evfd >= 0 ? SLOW_EV_NS : SLOW_NS;
    int64_t period = FAST_NS; // start fast for STILL_NS, then settle
    set_timer(tfd, period);
    drmEventContext ev = {.version = 2, .page_flip_handler = on_flip};

    bool animating = false, stepped_aside = false;
    int64_t last_frame = 0, last_motion = now_ns();
    double last_target = target;
    int read_errors = 0;
    unsigned long frames = 0, anim_frames = 0;
    double anim_from = shown;
    int64_t anim_t0 = 0;

    for (;;) {
        struct pollfd p[4] = {{sfd, POLLIN, 0}, {tfd, POLLIN, 0}, {k.fd, POLLIN, 0},
                              {acc.ev_on ? acc.evfd : -1, POLLIN, 0}};
        if (poll(p, 4, -1) < 0) {
            if (errno == EINTR)
                continue;
            logm("poll: %s", strerror(errno));
            break;
        }
        if (p[0].revents) {
            struct signalfd_siginfo si;
            if (read(sfd, &si, sizeof si) > 0)
                logm("signal %u; restoring fbdev and exiting (%lu frames drawn)", si.ssi_signo, frames);
            break;
        }
        int64_t now = now_ns();
        if (p[3].revents && accel_drain(&acc)) {
            // Motion: sample fast from the next tick on.
            last_motion = now;
            accel_events(&acc, false);
            if (period != FAST_NS)
                set_timer(tfd, period = FAST_NS);
        }
        if (p[1].revents & POLLIN) {
            uint64_t nexp;
            if (read(tfd, &nexp, sizeof nexp) < 0)
                nexp = 1;
            if (accel_read(&acc, g)) {
                read_errors = 0;
                double dt = (double)period / 1e9 * (double)nexp;
                double al = 1.0 - exp(-dt / TAU_S);
                gx += al * (g[0] - gx), gy += al * (g[1] - gy);
                double mag = hypot(gx, gy);
                if (flat ? mag > UNFLAT_MS2 : mag < FLAT_MS2) {
                    flat = !flat;
                    logm(flat ? "tablet flat (in-plane %.1f m/s^2): holding %+.1f deg" : "upright again (%.1f m/s^2)",
                         mag, target);
                }
                if (!flat)
                    target = shown + wrap180(atan2(gx, -gy) * 180 / M_PI - shown);
            } else if (++read_errors == 50) {
                logm("accelerometer read keeps failing; holding the angle");
            }
            if (fabs(target - last_target) > 0.2)
                last_motion = now;
            last_target = target;
            if (!animating && fabs(wrap180(target - shown)) > DEADBAND_DEG) {
                if (kms_acquire(&k)) {
                    animating = true;
                    last_frame = anim_t0 = now;
                    anim_from = shown, anim_frames = 0;
                } else if (!plymouth_running()) {
                    logm("another DRM master is active; stepping aside");
                    stepped_aside = true;
                    break;
                }
            }
            int64_t want = (animating || now - last_motion < STILL_NS) ? FAST_NS : slow_ns;
            if (want != period) {
                set_timer(tfd, period = want);
                accel_events(&acc, want != FAST_NS);
            }
        }
        if (p[2].revents & POLLIN)
            drmHandleEvent(k.fd, &ev);

        if (animating && !k.flip_pending) {
            if (plymouth_running()) { // shutdown splash: get out of its way
                animating = false;
                kms_release(&k);
                continue;
            }
            double dt = (now - last_frame) / 1e9;
            if (dt > 0.1)
                dt = 0.1;
            last_frame = now;
            // Critically damped spring towards target, in small steps.
            double err = target - shown;
            for (double left = dt; left > 0; left -= 0.004) {
                double h = left < 0.004 ? left : 0.004;
                double acc_ = OMEGA * OMEGA * err - 2 * OMEGA * vel;
                vel += acc_ * h;
                shown += vel * h;
                err = target - shown;
            }
            if (fabs(err) < SETTLE_DEG && fabs(vel) < SETTLE_VEL) {
                shown = target, vel = 0, animating = false;
            }
            if (kms_present(&k, shown))
                frames++, anim_frames++;
            else
                animating = false;
            if (!animating && fabs(shown - anim_from) >= 5.0)
                logm("turned %+.1f -> %+.1f deg (%lu frames, %.2f s)", wrap180(anim_from), wrap180(shown),
                     anim_frames, (now - anim_t0) / 1e9);
            if (!animating) {
                // keep the angle small; same picture
                double norm = wrap180(shown);
                target += norm - shown, last_target = target, shown = norm;
            }
        }
        if (!animating && !k.flip_pending && k.master)
            kms_release(&k);
    }
    if (stepped_aside)
        k.shown = false; // do not fight the new master over the CRTC
    // Let a pending flip finish before restoring fbdev.
    for (int i = 0; k.flip_pending && i < 10; i++) {
        struct pollfd p = {k.fd, POLLIN, 0};
        if (poll(&p, 1, 50) > 0)
            drmHandleEvent(k.fd, &ev);
    }
    kms_close(&k);
    accel_close(&acc);
    return 0;
}
