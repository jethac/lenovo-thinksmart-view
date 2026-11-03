// Clear and resolve a multisampled colour + depth/stencil framebuffer, to see
// whether freedreno can lay it out in GMEM.
//
//   gmem-msaa-test SAMPLES [CBUFS [WIDTH HEIGHT]]   (default 1 RGBA8 target, 800x1280)
//
// On a5xx with mesa-26.2.6, 4x RGBA8 + 4x DEPTH24_STENCIL8 counts the depth
// samples twice (16 + 64 bytes per pixel), more than even the smallest bin
// (64x32) of the A506's 136 KiB GMEM holds, and the bin search never ends:
// the flush spins on the CPU. Run it under `timeout`. With the GMEM patch it
// renders. 4x with 4 RGBA8 targets (64 + 16 bytes per pixel) does not fit
// even when counted right: that one needs the patch's sysmem fallback.
// Surfaceless EGL; libEGL.so.1 is opened at run time, so the Mesa in
// LD_LIBRARY_PATH is the one tested.
//
// Build: clang --target=aarch64-linux-gnu --sysroot=SYSROOT -isystem INCLUDE \
//          -fuse-ld=lld -O2 -o build/gmem-msaa-test gmem-msaa-test.c -ldl
#define EGL_NO_X11
#define GL_GLES_PROTOTYPES 0
#define EGL_EGL_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define EGLF(X)                                                                                                        \
    X(PFNEGLGETPLATFORMDISPLAYPROC, eglGetPlatformDisplay)                                                             \
    X(PFNEGLINITIALIZEPROC, eglInitialize)                                                                             \
    X(PFNEGLBINDAPIPROC, eglBindAPI)                                                                                   \
    X(PFNEGLCREATECONTEXTPROC, eglCreateContext)                                                                       \
    X(PFNEGLMAKECURRENTPROC, eglMakeCurrent)
#define GLF(X)                                                                                                         \
    X(PFNGLGETSTRINGPROC, glGetString)                                                                                 \
    X(PFNGLGETINTEGERVPROC, glGetIntegerv)                                                                             \
    X(PFNGLGETERRORPROC, glGetError)                                                                                   \
    X(PFNGLGENRENDERBUFFERSPROC, glGenRenderbuffers)                                                                   \
    X(PFNGLBINDRENDERBUFFERPROC, glBindRenderbuffer)                                                                   \
    X(PFNGLRENDERBUFFERSTORAGEMULTISAMPLEPROC, glRenderbufferStorageMultisample)                                       \
    X(PFNGLGENFRAMEBUFFERSPROC, glGenFramebuffers)                                                                     \
    X(PFNGLBINDFRAMEBUFFERPROC, glBindFramebuffer)                                                                     \
    X(PFNGLFRAMEBUFFERRENDERBUFFERPROC, glFramebufferRenderbuffer)                                                     \
    X(PFNGLCHECKFRAMEBUFFERSTATUSPROC, glCheckFramebufferStatus)                                                       \
    X(PFNGLVIEWPORTPROC, glViewport)                                                                                   \
    X(PFNGLCLEARCOLORPROC, glClearColor)                                                                               \
    X(PFNGLCLEARDEPTHFPROC, glClearDepthf)                                                                             \
    X(PFNGLCLEARSTENCILPROC, glClearStencil)                                                                           \
    X(PFNGLCLEARPROC, glClear)                                                                                         \
    X(PFNGLBLITFRAMEBUFFERPROC, glBlitFramebuffer)                                                                     \
    X(PFNGLREADPIXELSPROC, glReadPixels)                                                                               \
    X(PFNGLDRAWBUFFERSPROC, glDrawBuffers)                                                                             \
    X(PFNGLFINISHPROC, glFinish)
#define DECL(T, n) static T n;
EGLF(DECL)
GLF(DECL)

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void die(const char *m) {
    printf("error: %s\n", m);
    exit(1);
}

static GLuint fbo(int samples, int w, int h, int zs, int ncb) {
    GLuint rb[9], f;
    GLenum db[8];
    glGenRenderbuffers(9, rb);
    glGenFramebuffers(1, &f);
    glBindFramebuffer(GL_FRAMEBUFFER, f);
    for (int i = 0; i < ncb; i++) {
        glBindRenderbuffer(GL_RENDERBUFFER, rb[i]);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_RGBA8, w, h);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i, GL_RENDERBUFFER, rb[i]);
        db[i] = GL_COLOR_ATTACHMENT0 + i;
    }
    glDrawBuffers(ncb, db);
    if (zs) {
        glBindRenderbuffer(GL_RENDERBUFFER, rb[8]);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_DEPTH24_STENCIL8, w, h);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rb[8]);
    }
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) die("framebuffer incomplete");
    return f;
}

int main(int argc, char **argv) {
    if (argc != 2 && argc != 3 && argc != 5) die("usage: gmem-msaa-test SAMPLES [CBUFS [WIDTH HEIGHT]]");
    int samples = atoi(argv[1]), ncb = argc >= 3 ? atoi(argv[2]) : 1;
    int w = argc == 5 ? atoi(argv[3]) : 800, h = argc == 5 ? atoi(argv[4]) : 1280;
    if (ncb < 1 || ncb > 8) die("CBUFS: 1 to 8");
    setvbuf(stdout, NULL, _IOLBF, 0);
    void *lib = dlopen("libEGL.so.1", RTLD_NOW);
    if (!lib) die(dlerror());
    PFNEGLGETPROCADDRESSPROC gpa = (PFNEGLGETPROCADDRESSPROC)dlsym(lib, "eglGetProcAddress");
#define LOAD(T, n)                                                                                                     \
    if (!(n = (T)gpa(#n))) die("missing " #n);
    EGLF(LOAD)
    EGLDisplay d = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (!eglInitialize(d, NULL, NULL)) die("eglInitialize");
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint ca[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
    EGLContext c = eglCreateContext(d, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ca);
    if (c == EGL_NO_CONTEXT || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, c)) die("context");
    GLF(LOAD)
    GLint maxs = 0;
    glGetIntegerv(GL_MAX_SAMPLES, &maxs);
    printf("%s, GL_MAX_SAMPLES %d; %dx%d, %d samples, %d x RGBA8 + DEPTH24_STENCIL8\n",
           (const char *)glGetString(GL_RENDERER), maxs, w, h, samples, ncb);
    GLuint ms = fbo(samples, w, h, 1, ncb), one = fbo(0, w, h, 0, 1);
    double t0 = now();
    glBindFramebuffer(GL_FRAMEBUFFER, ms);
    glViewport(0, 0, w, h);
    glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
    glClearDepthf(0.5f);
    glClearStencil(1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, ms);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, one);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER, one);
    unsigned char px[4] = {0};
    glReadPixels(w / 2, h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glFinish();
    printf("rendered in %.1f ms, pixel %u %u %u %u (want 64 128 191 255), GL error 0x%x\n", (now() - t0) * 1000, px[0],
           px[1], px[2], px[3], glGetError());
    return !(px[0] > 60 && px[0] < 68 && px[1] > 124 && px[1] < 132);
}
