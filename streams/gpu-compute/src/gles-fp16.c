// gles-fp16: FP16 data paths on the Adreno 506 without GL_EXT_shader_16bit_storage.
//
// The same GEMM, C = A·B (A MxK, B KxN, row-major), four ways:
//
//   c32     compute, FP32 SSBOs, highp math                (the gles-sgemm r4x4 baseline)
//   p16     compute, A and B as packed halves in uint SSBOs (packHalf2x16), highp math
//   p16h    as p16, mediump math, FP16 partial sums folded into an FP32 total every KC steps
//   fN[h]   fragment shader, A and B in RGBA16F textures, C rendered to RGBA32F,
//           N rows of C per fragment (multiple render targets), h = mediump math with
//           FP16 partial sums folded into FP32 every KC steps
//
//   gles-fp16 bench M K N [kernel...]
//
// GFLOP/s is 2*M*N*K / kernel time (wall clock around glFinish, repeated for at least
// 0.5 s, uploads excluded: weights would be resident). Work is split into row bands of
// at most ~0.25 GFLOP per submission so the msm hangcheck never sees a long job.
// Error is reported against a double-precision reference on the FP32 inputs ("err")
// and on the FP16-rounded inputs ("arith", the arithmetic error alone), over 16 rows.
#define _GNU_SOURCE
#define EGL_NO_X11
#define GL_GLES_PROTOTYPES 0
#define EGL_EGL_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
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
    fprintf(stderr, "gles-fp16: %s\n", m);
    exit(1);
}

// ---- EGL / GL entry points (loaded at run time) ----
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
    X(PFNGLGENBUFFERSPROC, glGenBuffers)                                       \
    X(PFNGLDELETEBUFFERSPROC, glDeleteBuffers)                                 \
    X(PFNGLBINDBUFFERPROC, glBindBuffer)                                       \
    X(PFNGLBINDBUFFERBASEPROC, glBindBufferBase)                               \
    X(PFNGLBUFFERDATAPROC, glBufferData)                                       \
    X(PFNGLMAPBUFFERRANGEPROC, glMapBufferRange)                               \
    X(PFNGLUNMAPBUFFERPROC, glUnmapBuffer)                                     \
    X(PFNGLDISPATCHCOMPUTEPROC, glDispatchCompute)                             \
    X(PFNGLMEMORYBARRIERPROC, glMemoryBarrier)                                 \
    X(PFNGLFINISHPROC, glFinish)                                               \
    X(PFNGLFLUSHPROC, glFlush)                                                 \
    X(PFNGLGENTEXTURESPROC, glGenTextures)                                     \
    X(PFNGLDELETETEXTURESPROC, glDeleteTextures)                               \
    X(PFNGLBINDTEXTUREPROC, glBindTexture)                                     \
    X(PFNGLACTIVETEXTUREPROC, glActiveTexture)                                 \
    X(PFNGLTEXSTORAGE2DPROC, glTexStorage2D)                                   \
    X(PFNGLTEXSUBIMAGE2DPROC, glTexSubImage2D)                                 \
    X(PFNGLTEXPARAMETERIPROC, glTexParameteri)                                 \
    X(PFNGLGENFRAMEBUFFERSPROC, glGenFramebuffers)                             \
    X(PFNGLDELETEFRAMEBUFFERSPROC, glDeleteFramebuffers)                       \
    X(PFNGLBINDFRAMEBUFFERPROC, glBindFramebuffer)                             \
    X(PFNGLFRAMEBUFFERTEXTURE2DPROC, glFramebufferTexture2D)                   \
    X(PFNGLCHECKFRAMEBUFFERSTATUSPROC, glCheckFramebufferStatus)               \
    X(PFNGLDRAWBUFFERSPROC, glDrawBuffers)                                     \
    X(PFNGLREADBUFFERPROC, glReadBuffer)                                       \
    X(PFNGLREADPIXELSPROC, glReadPixels)                                       \
    X(PFNGLPIXELSTOREIPROC, glPixelStorei)                                     \
    X(PFNGLVIEWPORTPROC, glViewport)                                           \
    X(PFNGLSCISSORPROC, glScissor)                                             \
    X(PFNGLENABLEPROC, glEnable)                                               \
    X(PFNGLDISABLEPROC, glDisable)                                             \
    X(PFNGLGENVERTEXARRAYSPROC, glGenVertexArrays)                             \
    X(PFNGLBINDVERTEXARRAYPROC, glBindVertexArray)                             \
    X(PFNGLDRAWARRAYSPROC, glDrawArrays)
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
    fprintf(stderr, "renderer: %s / %s\n", p_glGetString(GL_RENDERER), p_glGetString(GL_VERSION));
}

// ---- FP16 on the host ----
static uint16_t f2h(float f)
{
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t s = (x >> 16) & 0x8000, e = (x >> 23) & 0xff, m = x & 0x7fffff;
    int ee = (int)e - 127 + 15;
    if (e == 0 || ee <= 0) return (uint16_t)s;  // inputs here are never subnormal in FP16
    if (ee >= 31) return (uint16_t)(s | 0x7c00);
    uint32_t h = s | ((uint32_t)ee << 10) | (m >> 13);
    uint32_t rem = m & 0x1fff;
    if (rem > 0x1000 || (rem == 0x1000 && (h & 1))) h++;  // round to nearest even
    return (uint16_t)h;
}

static float h2f(uint16_t h)
{
    uint32_t s = (uint32_t)(h & 0x8000) << 16, e = (h >> 10) & 0x1f, m = h & 0x3ff, x;
    if (e == 0) x = s;
    else if (e == 31) x = s | 0x7f800000 | (m << 13);
    else x = s | ((e - 15 + 127) << 23) | (m << 13);
    float f;
    memcpy(&f, &x, 4);
    return f;
}

// ---- shaders ----
// Compute: each invocation computes RM rows x 4 columns of C (one vec4 per row),
// K stepped by 4; local size 8x8. Same structure as gles-sgemm's r4x4_8x8.
static const char *cs_body =
    "layout(local_size_x=8, local_size_y=8) in;\n"
    "uniform int N4, K4, row0;\n"
    "#ifdef PACKED\n"
    "layout(std430, binding=0) readonly buffer BA { uvec2 a[]; };\n"
    "layout(std430, binding=1) readonly buffer BB { uvec2 b[]; };\n"
    "#define LD(arr, i) FT(unpackHalf2x16(arr[i].x), unpackHalf2x16(arr[i].y))\n"
    "#else\n"
    "layout(std430, binding=0) readonly buffer BA { vec4 a[]; };\n"
    "layout(std430, binding=1) readonly buffer BB { vec4 b[]; };\n"
    "#define LD(arr, i) FT(arr[i])\n"
    "#endif\n"
    "layout(std430, binding=2) writeonly buffer BC { vec4 c[]; };\n"
    "void main() {\n"
    "  int n4 = int(gl_GlobalInvocationID.x);\n"
    "  int m = row0 + int(gl_GlobalInvocationID.y) * RM;\n"
    "  highp vec4 acc[RM];\n"
    "  FT part[RM];\n"
    "  for (int r = 0; r < RM; r++) { acc[r] = vec4(0.0); part[r] = FT(0.0); }\n"
    "  for (int k4 = 0; k4 < K4; k4++) {\n"
    "    int kk = k4 << 2;\n"
    "    FT b0 = LD(b, kk*N4 + n4), b1 = LD(b, (kk+1)*N4 + n4), b2 = LD(b, (kk+2)*N4 + n4), b3 = LD(b, (kk+3)*N4 + n4);\n"
    "    for (int r = 0; r < RM; r++) {\n"
    "      FT x = LD(a, (m + r)*K4 + k4);\n"
    "      part[r] += x.x*b0 + x.y*b1 + x.z*b2 + x.w*b3;\n"
    "    }\n"
    "    if ((k4 & (KC - 1)) == KC - 1) for (int r = 0; r < RM; r++) { acc[r] += vec4(part[r]); part[r] = FT(0.0); }\n"
    "  }\n"
    "  for (int r = 0; r < RM; r++) c[(m + r)*N4 + n4] = acc[r] + vec4(part[r]);\n"
    "}\n";

static const char *vs_src =
    "#version 310 es\n"
    "void main() {\n"  // one triangle covering the viewport
    "  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
    "  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

// Fragment: the fragment at (n4, y) computes rows y*RM .. y*RM+RM-1, columns 4*n4..+3,
// written to render target r. A is K4 x M (RGBA16F, x = k4, y = row), B is N4 x K.
static const char *fs_body =
    "uniform SP sampler2D ta, tb;\n"
    "uniform int K4;\n"
    "layout(location=0) out highp vec4 o0;\n"
    "#if RM > 1\nlayout(location=1) out highp vec4 o1;\n#endif\n"
    "#if RM > 2\nlayout(location=2) out highp vec4 o2;\nlayout(location=3) out highp vec4 o3;\n#endif\n"
    "void main() {\n"
    "  int n4 = int(gl_FragCoord.x), m = int(gl_FragCoord.y) * RM;\n"
    "  highp vec4 acc[RM];\n"
    "  FT part[RM];\n"
    "  for (int r = 0; r < RM; r++) { acc[r] = vec4(0.0); part[r] = FT(0.0); }\n"
    "  for (int k4 = 0; k4 < K4; k4++) {\n"
    "    int kk = k4 << 2;\n"
    "    FT b0 = texelFetch(tb, ivec2(n4, kk), 0), b1 = texelFetch(tb, ivec2(n4, kk+1), 0);\n"
    "    FT b2 = texelFetch(tb, ivec2(n4, kk+2), 0), b3 = texelFetch(tb, ivec2(n4, kk+3), 0);\n"
    "    for (int r = 0; r < RM; r++) {\n"
    "      FT x = texelFetch(ta, ivec2(k4, m + r), 0);\n"
    "      part[r] += x.x*b0 + x.y*b1 + x.z*b2 + x.w*b3;\n"
    "    }\n"
    "    if ((k4 & (KC - 1)) == KC - 1) for (int r = 0; r < RM; r++) { acc[r] += vec4(part[r]); part[r] = FT(0.0); }\n"
    "  }\n"
    "  o0 = acc[0] + vec4(part[0]);\n"
    "#if RM > 1\n  o1 = acc[1] + vec4(part[1]);\n#endif\n"
    "#if RM > 2\n  o2 = acc[2] + vec4(part[2]);\n  o3 = acc[3] + vec4(part[3]);\n#endif\n"
    "}\n";

typedef struct {
    const char *name;
    int frag;    // 0 compute, 1 fragment
    int packed;  // compute: packed halves
    int half;    // mediump math with FP16 partial sums
    int rm;      // rows of C per invocation/fragment
} kernel_t;

static const kernel_t kernels[] = {
    {"c32", 0, 0, 0, 4},  {"c32h", 0, 0, 1, 4}, {"p16", 0, 1, 0, 4}, {"p16h", 0, 1, 1, 4},
    {"f1", 1, 0, 0, 1},   {"f1h", 1, 0, 1, 1},  {"f4", 1, 0, 0, 4},  {"f4h", 1, 0, 1, 4},
    {"f2h", 1, 0, 1, 2},
};
#define NKERNELS (int)(sizeof kernels / sizeof kernels[0])
static double chunk_gflop = 0.05;  // per submission, env CHUNK
static int KC = 16;  // k4 steps (64 MACs per output) between FP16 -> FP32 folds

static GLuint shader(GLenum type, const char **src, int n, const char *name)
{
    GLuint s = p_glCreateShader(type);
    p_glShaderSource(s, n, src, NULL);
    p_glCompileShader(s);
    GLint ok;
    char log[4096];
    p_glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        p_glGetShaderInfoLog(s, sizeof log, NULL, log);
        fprintf(stderr, "%s: compile failed:\n%s\n", name, log);
        exit(1);
    }
    return s;
}

static GLuint build(const kernel_t *k)
{
    char defs[512];
    snprintf(defs, sizeof defs,
             "#version 310 es\nprecision highp float;\nprecision highp int;\n"
             "#define RM %d\n#define KC %d\n#define FT vec4\n#define SP %s\n%s%s",
             k->rm, KC, k->half ? "mediump" : "highp", k->half ? "precision mediump float;\n" : "",
             k->packed ? "#define PACKED\n" : "");
    GLuint p = p_glCreateProgram();
    if (k->frag) {
        const char *v[] = {vs_src}, *f[] = {defs, fs_body};
        GLuint vs = shader(GL_VERTEX_SHADER, v, 1, k->name), fs = shader(GL_FRAGMENT_SHADER, f, 2, k->name);
        p_glAttachShader(p, vs);
        p_glAttachShader(p, fs);
        p_glLinkProgram(p);
        p_glDeleteShader(vs);
        p_glDeleteShader(fs);
    } else {
        const char *c[] = {defs, cs_body};
        GLuint cs = shader(GL_COMPUTE_SHADER, c, 2, k->name);
        p_glAttachShader(p, cs);
        p_glLinkProgram(p);
        p_glDeleteShader(cs);
    }
    GLint ok;
    char log[4096];
    p_glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        p_glGetProgramInfoLog(p, sizeof log, NULL, log);
        fprintf(stderr, "%s: link failed:\n%s\n", k->name, log);
        exit(1);
    }
    return p;
}

// ---- problem ----
static int M, K, N;
static float *A, *B;            // FP32 inputs
static float *Ah, *Bh;          // the same, rounded to FP16 (as floats)
static uint16_t *A16, *B16;     // FP16 bits
static float *C;                // result
static int check_rows[16];

static uint32_t rng = 12345;
static float frand(void)
{
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xffffff) / 8388608.0f - 1.0f;
}

static void prob_init(void)
{
    size_t na = (size_t)M * K, nb = (size_t)K * N;
    A = malloc(na * 4); B = malloc(nb * 4); Ah = malloc(na * 4); Bh = malloc(nb * 4);
    A16 = malloc(na * 2); B16 = malloc(nb * 2); C = malloc((size_t)M * N * 4);
    for (size_t i = 0; i < na; i++) { A[i] = frand(); A16[i] = f2h(A[i]); Ah[i] = h2f(A16[i]); }
    for (size_t i = 0; i < nb; i++) { B[i] = frand(); B16[i] = f2h(B[i]); Bh[i] = h2f(B16[i]); }
    for (int i = 0; i < 16; i++) check_rows[i] = (int)((uint64_t)i * (M - 1) / 15);
}

static void check(int fp16_inputs, double *err, double *arith, double *ref_max)
{
    *err = *arith = *ref_max = 0;
    for (int ci = 0; ci < 16; ci++) {
        int m = check_rows[ci];
        for (int n = 0; n < N; n++) {
            double r = 0, rh = 0;
            for (int k = 0; k < K; k++) {
                r += (double)A[(size_t)m * K + k] * B[(size_t)k * N + n];
                rh += (double)Ah[(size_t)m * K + k] * Bh[(size_t)k * N + n];
            }
            double c = C[(size_t)m * N + n];
            if (fabs(r) > *ref_max) *ref_max = fabs(r);
            if (fabs(c - r) > *err) *err = fabs(c - r);
            double ra = fp16_inputs ? rh : r;
            if (fabs(c - ra) > *arith) *arith = fabs(c - ra);
        }
    }
}

// ---- compute path ----
static GLuint buf[3];
static void cs_upload(const kernel_t *k)
{
    size_t na = (size_t)M * K, nb = (size_t)K * N;
    if (!buf[0]) p_glGenBuffers(3, buf);
    const void *pa = k->packed ? (const void *)A16 : (const void *)A;
    const void *pb = k->packed ? (const void *)B16 : (const void *)B;
    size_t es = k->packed ? 2 : 4;
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[0]);
    p_glBufferData(GL_SHADER_STORAGE_BUFFER, na * es, pa, GL_STATIC_DRAW);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[1]);
    p_glBufferData(GL_SHADER_STORAGE_BUFFER, nb * es, pb, GL_STATIC_DRAW);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[2]);
    p_glBufferData(GL_SHADER_STORAGE_BUFFER, (size_t)M * N * 4, NULL, GL_DYNAMIC_READ);
    for (int i = 0; i < 3; i++) p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, i, buf[i]);
}

static int band_rows(int unit)
{
    // rows per submission so each is <= ~0.25 GFLOP, a multiple of `unit`
    double per_row = 2.0 * K * N;
    int r = (int)(chunk_gflop * 1e9 / per_row) / unit * unit;
    if (r < unit) r = unit;
    if (r > M) r = M;
    return r;
}

static void cs_run(const kernel_t *k, GLuint prog)
{
    p_glUseProgram(prog);
    p_glUniform1i(p_glGetUniformLocation(prog, "N4"), N / 4);
    p_glUniform1i(p_glGetUniformLocation(prog, "K4"), K / 4);
    GLint lrow = p_glGetUniformLocation(prog, "row0");
    int unit = 8 * k->rm, band = band_rows(unit);
    for (int r0 = 0; r0 < M; r0 += band) {
        int nr = M - r0 < band ? M - r0 : band;
        p_glUniform1i(lrow, r0);
        p_glDispatchCompute(N / 4 / 8, nr / unit, 1);
        p_glFlush();
    }
}

static void cs_read(void)
{
    p_glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf[2]);
    void *p = p_glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, (size_t)M * N * 4, GL_MAP_READ_BIT);
    if (!p) die("map C");
    memcpy(C, p, (size_t)M * N * 4);
    p_glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
}

// ---- fragment path ----
static GLuint tex_a, tex_b, tex_c[4], fbo, vao;
static void fs_upload(const kernel_t *k)
{
    if (!tex_a) {
        p_glGenTextures(1, &tex_a);
        p_glBindTexture(GL_TEXTURE_2D, tex_a);
        p_glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA16F, K / 4, M);
        p_glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        p_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, K / 4, M, GL_RGBA, GL_HALF_FLOAT, A16);
        p_glGenTextures(1, &tex_b);
        p_glBindTexture(GL_TEXTURE_2D, tex_b);
        p_glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA16F, N / 4, K);
        p_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, N / 4, K, GL_RGBA, GL_HALF_FLOAT, B16);
        p_glGenFramebuffers(1, &fbo);
        p_glGenVertexArrays(1, &vao);
    }
    for (int t = 0; t < 4; t++) {
        if (tex_c[t]) p_glDeleteTextures(1, &tex_c[t]);
        tex_c[t] = 0;
    }
    p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    GLenum dbs[4];
    for (int t = 0; t < k->rm; t++) {
        p_glGenTextures(1, &tex_c[t]);
        p_glBindTexture(GL_TEXTURE_2D, tex_c[t]);
        p_glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, N / 4, M / k->rm);
        p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + t, GL_TEXTURE_2D, tex_c[t], 0);
        dbs[t] = GL_COLOR_ATTACHMENT0 + t;
    }
    for (int t = k->rm; t < 4; t++) p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + t, GL_TEXTURE_2D, 0, 0);
    p_glDrawBuffers(k->rm, dbs);
    if (p_glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) die("framebuffer incomplete (RGBA32F MRT)");
}

static void fs_run(const kernel_t *k, GLuint prog)
{
    p_glUseProgram(prog);
    p_glActiveTexture(GL_TEXTURE0);
    p_glBindTexture(GL_TEXTURE_2D, tex_a);
    p_glActiveTexture(GL_TEXTURE1);
    p_glBindTexture(GL_TEXTURE_2D, tex_b);
    p_glUniform1i(p_glGetUniformLocation(prog, "ta"), 0);
    p_glUniform1i(p_glGetUniformLocation(prog, "tb"), 1);
    p_glUniform1i(p_glGetUniformLocation(prog, "K4"), K / 4);
    p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    p_glBindVertexArray(vao);
    int H = M / k->rm, band = band_rows(k->rm) / k->rm;
    p_glViewport(0, 0, N / 4, H);
    p_glEnable(GL_SCISSOR_TEST);
    for (int y0 = 0; y0 < H; y0 += band) {
        int ny = H - y0 < band ? H - y0 : band;
        p_glScissor(0, y0, N / 4, ny);
        p_glDrawArrays(GL_TRIANGLES, 0, 3);
        p_glFlush();
    }
    p_glDisable(GL_SCISSOR_TEST);
}

static void fs_read(const kernel_t *k)
{
    int H = M / k->rm, W = N / 4;
    float *tmp = malloc((size_t)W * H * 16);
    p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    for (int t = 0; t < k->rm; t++) {
        p_glReadBuffer(GL_COLOR_ATTACHMENT0 + t);
        p_glReadPixels(0, 0, W, H, GL_RGBA, GL_FLOAT, tmp);
        for (int y = 0; y < H; y++) memcpy(&C[(size_t)(y * k->rm + t) * N], &tmp[(size_t)y * W * 4], (size_t)N * 4);
    }
    free(tmp);
}

// ---- bench ----
static void bench_one(const kernel_t *k)
{
    if (N % 32 || K % (4 * KC) || M % (8 * k->rm)) {
        printf("%-6s skipped: shape must have N%%32, K%%%d, M%%%d == 0\n", k->name, 4 * KC, 8 * k->rm);
        return;
    }
    GLuint prog = build(k);
    if (k->frag) fs_upload(k);
    else cs_upload(k);
    // warm up (compiles the variant, faults show here)
    if (k->frag) fs_run(k, prog);
    else cs_run(k, prog);
    p_glFinish();
    int iters = 0;
    double t0 = now(), t;
    do {
        if (k->frag) fs_run(k, prog);
        else cs_run(k, prog);
        p_glFinish();
        iters++;
        t = now() - t0;
    } while (t < 0.5);
    double gf = 2.0 * M * N * K * iters / t / 1e9;
    memset(C, 0, (size_t)M * N * 4);
    if (k->frag) fs_read(k);
    else cs_read();
    GLenum e = p_glGetError();
    double err, arith, rmax;
    check(k->frag || k->packed, &err, &arith, &rmax);
    int bad = !(err < rmax) || e != GL_NO_ERROR;
    printf("%-6s %7.2f GFLOP/s  %5.1f ms  err %.3g  arith %.3g  (|C| max %.1f)%s\n", k->name, gf, t / iters * 1e3, err,
           arith, rmax, bad ? "  INVALID" : "");
    fflush(stdout);
    p_glDeleteProgram(prog);
}

int main(int argc, char **argv)
{
    if (argc < 5 || strcmp(argv[1], "bench")) {
        fprintf(stderr, "usage: gles-fp16 bench M K N [kernel...]   (env KC=k4 steps per FP16 fold, default 16)\n");
        return 2;
    }
    if (getenv("KC")) KC = atoi(getenv("KC"));
    if (getenv("CHUNK")) chunk_gflop = atof(getenv("CHUNK"));
    M = atoi(argv[2]);
    K = atoi(argv[3]);
    N = atoi(argv[4]);
    gl_init();
    prob_init();
    printf("M=%d K=%d N=%d KC=%d (%d MACs per FP16 partial sum)\n", M, K, N, KC, 4 * KC);
    for (int i = 0; i < NKERNELS; i++) {
        int want = argc == 5;
        for (int j = 5; j < argc; j++) want |= !strcmp(argv[j], kernels[i].name);
        if (want) bench_one(&kernels[i]);
    }
    return 0;
}
