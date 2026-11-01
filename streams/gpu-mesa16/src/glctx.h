// Surfaceless EGL + GLES 3.1 context with run-time loaded entry points
// (dlopen libEGL.so.1, so the Mesa in LD_LIBRARY_PATH is used). Shared by
// the gpu-mesa16 test programs. Same scheme as streams/gpu-compute.
#pragma once
#define _GNU_SOURCE
#define EGL_NO_X11
#define GL_GLES_PROTOTYPES 0
#define EGL_EGL_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void die(const char *m)
{
    fprintf(stderr, "error: %s\n", m);
    exit(1);
}

static PFNEGLGETPROCADDRESSPROC p_eglGetProcAddress;
#define EGLF(X)                                                                \
    X(PFNEGLGETPLATFORMDISPLAYPROC, eglGetPlatformDisplay)                     \
    X(PFNEGLINITIALIZEPROC, eglInitialize)                                     \
    X(PFNEGLBINDAPIPROC, eglBindAPI)                                           \
    X(PFNEGLCREATECONTEXTPROC, eglCreateContext)                               \
    X(PFNEGLMAKECURRENTPROC, eglMakeCurrent)                                   \
    X(PFNEGLGETERRORPROC, eglGetError)
#define GLF(X)                                                                 \
    X(PFNGLGETSTRINGPROC, glGetString)                                         \
    X(PFNGLGETSTRINGIPROC, glGetStringi)                                       \
    X(PFNGLGETINTEGERVPROC, glGetIntegerv)                                     \
    X(PFNGLGETERRORPROC, glGetError)                                           \
    X(PFNGLCREATESHADERPROC, glCreateShader)                                   \
    X(PFNGLSHADERSOURCEPROC, glShaderSource)                                   \
    X(PFNGLCOMPILESHADERPROC, glCompileShader)                                 \
    X(PFNGLGETSHADERIVPROC, glGetShaderiv)                                     \
    X(PFNGLGETSHADERINFOLOGPROC, glGetShaderInfoLog)                           \
    X(PFNGLCREATEPROGRAMPROC, glCreateProgram)                                 \
    X(PFNGLATTACHSHADERPROC, glAttachShader)                                   \
    X(PFNGLLINKPROGRAMPROC, glLinkProgram)                                     \
    X(PFNGLGETPROGRAMIVPROC, glGetProgramiv)                                   \
    X(PFNGLGETPROGRAMINFOLOGPROC, glGetProgramInfoLog)                         \
    X(PFNGLUSEPROGRAMPROC, glUseProgram)                                       \
    X(PFNGLDELETEPROGRAMPROC, glDeleteProgram)                                 \
    X(PFNGLDELETESHADERPROC, glDeleteShader)                                   \
    X(PFNGLGETUNIFORMLOCATIONPROC, glGetUniformLocation)                       \
    X(PFNGLUNIFORM1IPROC, glUniform1i)                                         \
    X(PFNGLUNIFORM1UIPROC, glUniform1ui)                                       \
    X(PFNGLUNIFORM4FVPROC, glUniform4fv)                                       \
    X(PFNGLGENBUFFERSPROC, glGenBuffers)                                       \
    X(PFNGLDELETEBUFFERSPROC, glDeleteBuffers)                                 \
    X(PFNGLBINDBUFFERPROC, glBindBuffer)                                       \
    X(PFNGLBINDBUFFERBASEPROC, glBindBufferBase)                               \
    X(PFNGLBUFFERDATAPROC, glBufferData)                                       \
    X(PFNGLBUFFERSUBDATAPROC, glBufferSubData)                                 \
    X(PFNGLMAPBUFFERRANGEPROC, glMapBufferRange)                               \
    X(PFNGLUNMAPBUFFERPROC, glUnmapBuffer)                                     \
    X(PFNGLDISPATCHCOMPUTEPROC, glDispatchCompute)                             \
    X(PFNGLMEMORYBARRIERPROC, glMemoryBarrier)                                 \
    X(PFNGLFINISHPROC, glFinish)                                               \
    X(PFNGLFLUSHPROC, glFlush)
#define DECL(T, n) static T p_##n;
EGLF(DECL)
GLF(DECL)
#define LOAD(T, n)                                                             \
    if (!(p_##n = (T)p_eglGetProcAddress(#n))) die("missing " #n);

static void gl_init(void)
{
    void *egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!egl) die(dlerror());
    p_eglGetProcAddress = (PFNEGLGETPROCADDRESSPROC)dlsym(egl, "eglGetProcAddress");
    if (!p_eglGetProcAddress) die("no eglGetProcAddress");
    EGLF(LOAD)
    EGLDisplay dpy = p_eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint maj, min;
    if (dpy == EGL_NO_DISPLAY || !p_eglInitialize(dpy, &maj, &min)) die("eglInitialize (surfaceless)");
    if (!p_eglBindAPI(EGL_OPENGL_ES_API)) die("eglBindAPI");
    EGLint attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE};
    EGLContext ctx = p_eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
    if (ctx == EGL_NO_CONTEXT) die("no GLES 3.1 context");
    if (!p_eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) die("eglMakeCurrent");
    GLF(LOAD)
}

static int has_ext(const char *name)
{
    GLint n = 0;
    p_glGetIntegerv(GL_NUM_EXTENSIONS, &n);
    for (GLint i = 0; i < n; i++)
        if (!strcmp((const char *)p_glGetStringi(GL_EXTENSIONS, i), name)) return 1;
    return 0;
}

// Compile and link a compute program; returns 0 (and prints the log) on failure.
static GLuint make_prog(const char *src, int quiet)
{
    GLuint s = p_glCreateShader(GL_COMPUTE_SHADER);
    p_glShaderSource(s, 1, &src, NULL);
    p_glCompileShader(s);
    GLint ok = 0;
    p_glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    char log[4096];
    if (!ok) {
        p_glGetShaderInfoLog(s, sizeof log, NULL, log);
        if (!quiet) fprintf(stderr, "compile failed:\n%s\n", log);
        p_glDeleteShader(s);
        return 0;
    }
    GLuint p = p_glCreateProgram();
    p_glAttachShader(p, s);
    p_glLinkProgram(p);
    p_glDeleteShader(s);
    p_glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        p_glGetProgramInfoLog(p, sizeof log, NULL, log);
        if (!quiet) fprintf(stderr, "link failed:\n%s\n", log);
        p_glDeleteProgram(p);
        return 0;
    }
    return p;
}

static GLuint make_ssbo(GLuint binding, size_t bytes, const void *data)
{
    GLuint b;
    p_glGenBuffers(1, &b);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, b);
    p_glBufferData(GL_SHADER_STORAGE_BUFFER, bytes, data, GL_DYNAMIC_COPY);
    p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, binding, b);
    return b;
}

static void read_ssbo(GLuint b, size_t bytes, void *out)
{
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, b);
    void *m = p_glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, bytes, GL_MAP_READ_BIT);
    if (!m) die("glMapBufferRange");
    memcpy(out, m, bytes);
    p_glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
}

static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) die(path);
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    char *s = malloc(n + 1);
    if (fread(s, 1, n, f) != (size_t)n) die("read");
    s[n] = 0;
    fclose(f);
    return s;
}
