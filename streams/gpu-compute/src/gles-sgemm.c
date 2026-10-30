// gles-sgemm: FP32 matrix multiplication C = A·B as OpenGL ES 3.1 compute
// shaders, on a surfaceless EGL context (render node only, no DRM master).
//
// A is MxK, B is KxN, C is MxN, all row-major FP32 in SSBOs. Matrices are
// zero-padded on the host to the kernel's tile multiples; GFLOP/s is always
// 2*M*N*K (unpadded) / time.
//
//   gles-sgemm info                         print context, limits, extensions
//   gles-sgemm bench M K N [kernel...]      time kernels on one shape
//   gles-sgemm soak SECONDS M K N kernel    run one kernel continuously
//
// Kernels: naive8 naive16 tile8 tile16 r4x4_8x8 r4x4_16x4 r8x4_8x8
//          r4x4_16x4 r4x4_4x16 r4x4_8x8h st32 st64x32 st64r8 st64r8k32 st128r8 st64r8h
//          and texture-B variants r4x4t{8,16,32}[h] st64r8t{8,16,32}[h]; "h" = mediump
//
// Timing is wall clock around glFinish(). Kernels that would run longer than
// about 50 ms per dispatch are split into row chunks so the msm hangcheck
// never sees one long job.
#define _GNU_SOURCE
#define EGL_NO_X11
#define GL_GLES_PROTOTYPES 0
#define EGL_EGL_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#ifndef GL_MAX_TEXTURE_BUFFER_SIZE
#define GL_MAX_TEXTURE_BUFFER_SIZE 0x8C2B  // GL_EXT_texture_buffer, core in 3.2
#endif
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void die(const char *m)
{
    fprintf(stderr, "gles-sgemm: %s\n", m);
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
    X(PFNEGLQUERYSTRINGPROC, eglQueryString)                                   \
    X(PFNEGLGETERRORPROC, eglGetError)                                         \
    X(PFNEGLTERMINATEPROC, eglTerminate)
#define GLF(X)                                                                 \
    X(PFNGLGETSTRINGPROC, glGetString)                                         \
    X(PFNGLGETSTRINGIPROC, glGetStringi)                                       \
    X(PFNGLGETINTEGERVPROC, glGetIntegerv)                                     \
    X(PFNGLGETINTEGERI_VPROC, glGetIntegeri_v)                                 \
    X(PFNGLGETINTEGER64VPROC, glGetInteger64v)                                 \
    X(PFNGLGETSHADERPRECISIONFORMATPROC, glGetShaderPrecisionFormat)           \
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
    X(PFNGLBUFFERSUBDATAPROC, glBufferSubData)                                 \
    X(PFNGLMAPBUFFERRANGEPROC, glMapBufferRange)                               \
    X(PFNGLUNMAPBUFFERPROC, glUnmapBuffer)                                     \
    X(PFNGLDISPATCHCOMPUTEPROC, glDispatchCompute)                             \
    X(PFNGLMEMORYBARRIERPROC, glMemoryBarrier)                                 \
    X(PFNGLFINISHPROC, glFinish)                                               \
    X(PFNGLFLUSHPROC, glFlush)                                               \
    X(PFNGLGENTEXTURESPROC, glGenTextures)                                     \
    X(PFNGLDELETETEXTURESPROC, glDeleteTextures)                               \
    X(PFNGLBINDTEXTUREPROC, glBindTexture)                                     \
    X(PFNGLACTIVETEXTUREPROC, glActiveTexture)                                 \
    X(PFNGLTEXSTORAGE2DPROC, glTexStorage2D)                                   \
    X(PFNGLTEXSUBIMAGE2DPROC, glTexSubImage2D)                                 \
    X(PFNGLTEXPARAMETERIPROC, glTexParameteri)
#define DECL(T, n) static T p_##n;
EGLF(DECL)
GLF(DECL)
#define LOAD(T, n)                                                             \
    if (!(p_##n = (T)p_eglGetProcAddress(#n))) die("missing " #n);

static EGLDisplay dpy;

static void gl_init(void)
{
    void *egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!egl) die(dlerror());
    p_eglGetProcAddress = (PFNEGLGETPROCADDRESSPROC)dlsym(egl, "eglGetProcAddress");
    if (!p_eglGetProcAddress) die("no eglGetProcAddress");
    EGLF(LOAD)
    dpy = p_eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint maj, min;
    if (dpy == EGL_NO_DISPLAY || !p_eglInitialize(dpy, &maj, &min)) die("eglInitialize (surfaceless)");
    if (!p_eglBindAPI(EGL_OPENGL_ES_API)) die("eglBindAPI");
    static const int vers[][2] = {{3, 2}, {3, 1}};
    EGLContext ctx = EGL_NO_CONTEXT;
    for (unsigned i = 0; i < 2 && ctx == EGL_NO_CONTEXT; i++) {
        EGLint attr[] = {EGL_CONTEXT_MAJOR_VERSION, vers[i][0], EGL_CONTEXT_MINOR_VERSION, vers[i][1], EGL_NONE};
        ctx = p_eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attr);
        if (ctx != EGL_NO_CONTEXT) fprintf(stderr, "context: requested GLES %d.%d: ok\n", vers[i][0], vers[i][1]);
        else fprintf(stderr, "context: requested GLES %d.%d: 0x%x\n", vers[i][0], vers[i][1], p_eglGetError());
    }
    if (ctx == EGL_NO_CONTEXT) die("no GLES 3.1+ context");
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

static void info(void)
{
    printf("EGL_VENDOR      %s\n", p_eglQueryString(dpy, EGL_VENDOR));
    printf("EGL_VERSION     %s\n", p_eglQueryString(dpy, EGL_VERSION));
    printf("GL_VENDOR       %s\n", p_glGetString(GL_VENDOR));
    printf("GL_RENDERER     %s\n", p_glGetString(GL_RENDERER));
    printf("GL_VERSION      %s\n", p_glGetString(GL_VERSION));
    printf("GL_SHADING_LANGUAGE_VERSION %s\n", p_glGetString(GL_SHADING_LANGUAGE_VERSION));
    GLint v[3];
    for (int i = 0; i < 3; i++) p_glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, i, &v[i]);
    printf("GL_MAX_COMPUTE_WORK_GROUP_COUNT %d %d %d\n", v[0], v[1], v[2]);
    for (int i = 0; i < 3; i++) p_glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, i, &v[i]);
    printf("GL_MAX_COMPUTE_WORK_GROUP_SIZE %d %d %d\n", v[0], v[1], v[2]);
    struct { GLenum e; const char *n; } q[] = {
        {GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, "GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS"},
        {GL_MAX_COMPUTE_SHARED_MEMORY_SIZE, "GL_MAX_COMPUTE_SHARED_MEMORY_SIZE"},
        {GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS, "GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS"},
        {GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS, "GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS"},
        {GL_MAX_COMPUTE_UNIFORM_COMPONENTS, "GL_MAX_COMPUTE_UNIFORM_COMPONENTS"},
        {GL_MAX_COMPUTE_IMAGE_UNIFORMS, "GL_MAX_COMPUTE_IMAGE_UNIFORMS"},
        {GL_MAX_COMPUTE_TEXTURE_IMAGE_UNITS, "GL_MAX_COMPUTE_TEXTURE_IMAGE_UNITS"},
        {GL_MAX_TEXTURE_BUFFER_SIZE, "GL_MAX_TEXTURE_BUFFER_SIZE"},
        {GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT, "GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT"},
        {GL_MAX_TEXTURE_SIZE, "GL_MAX_TEXTURE_SIZE"},
    };
    for (unsigned i = 0; i < sizeof q / sizeof q[0]; i++) {
        GLint x = -1;
        p_glGetIntegerv(q[i].e, &x);
        printf("%s %d\n", q[i].n, x);
    }
    GLint64 ssbo = -1;
    p_glGetInteger64v(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &ssbo);
    printf("GL_MAX_SHADER_STORAGE_BLOCK_SIZE %lld\n", (long long)ssbo);
    static const struct { GLenum e; const char *n; } pf[] = {
        {GL_LOW_FLOAT, "lowp float"}, {GL_MEDIUM_FLOAT, "mediump float"}, {GL_HIGH_FLOAT, "highp float"},
        {GL_MEDIUM_INT, "mediump int"}, {GL_HIGH_INT, "highp int"}};
    for (unsigned i = 0; i < 5; i++) {
        GLint r[2], p;
        r[0] = r[1] = p = -1;
        p_glGetShaderPrecisionFormat(GL_FRAGMENT_SHADER, pf[i].e, r, &p);  // GLES accepts only vertex/fragment here
        printf("fragment precision %-13s range %d,%d precision %d\n", pf[i].n, r[0], r[1], p);
    }
    GLint n = 0;
    p_glGetIntegerv(GL_NUM_EXTENSIONS, &n);
    printf("GL_EXTENSIONS (%d):", n);
    for (GLint i = 0; i < n; i++) printf(" %s", p_glGetStringi(GL_EXTENSIONS, i));
    printf("\n");
    static const char *want[] = {"GL_EXT_shader_16bit_storage", "GL_EXT_shader_explicit_arithmetic_types_float16",
        "GL_AMD_gpu_shader_half_float", "GL_EXT_shader_framebuffer_fetch", "GL_EXT_disjoint_timer_query",
        "GL_KHR_shader_subgroup", "GL_EXT_buffer_storage", "GL_EXT_texture_buffer", "GL_OES_shader_image_atomic",
        "GL_EXT_shader_integer_mix", "GL_EXT_color_buffer_half_float", "GL_OES_texture_half_float"};
    for (unsigned i = 0; i < sizeof want / sizeof want[0]; i++)
        printf("  %-48s %s\n", want[i], has_ext(want[i]) ? "yes" : "no");
}

// ---- kernels ----
typedef struct {
    const char *name;
    int bm, bn, bk;  // C tile per work group (rows, cols), K multiple
    int lx, ly;      // local size
    const char *body;
    const char *defs;
    int texb;        // B source: 0 SSBO FP32, else texture RGBA8_SNORM (8), RGBA16F (16), RGBA32F (32)
} kernel_t;

static const char *hdr =
    "#version 310 es\n"
    "precision highp float;\nprecision highp int;\n"
    "uniform int M, N, K, row0;\n";

// One output per invocation, scalar loads.
static const char *k_naive =
    "layout(std430, binding=0) readonly buffer BA { float a[]; };\n"
    "layout(std430, binding=1) readonly buffer BB { float b[]; };\n"
    "layout(std430, binding=2) writeonly buffer BC { float c[]; };\n"
    "void main() {\n"
    "  int n = int(gl_GlobalInvocationID.x), m = row0 + int(gl_GlobalInvocationID.y);\n"
    "  float s = 0.0;\n"
    "  for (int k = 0; k < K; k++) s += a[m*K + k] * b[k*N + n];\n"
    "  c[m*N + n] = s;\n"
    "}\n";

// Classic shared-memory tiling, TS x TS tile, one output per invocation.
static const char *k_tile =
    "layout(std430, binding=0) readonly buffer BA { float a[]; };\n"
    "layout(std430, binding=1) readonly buffer BB { float b[]; };\n"
    "layout(std430, binding=2) writeonly buffer BC { float c[]; };\n"
    "shared float sa[TS][TS];\nshared float sb[TS][TS];\n"
    "void main() {\n"
    "  int tx = int(gl_LocalInvocationID.x), ty = int(gl_LocalInvocationID.y);\n"
    "  int n = int(gl_GlobalInvocationID.x), m = row0 + int(gl_GlobalInvocationID.y);\n"
    "  float s = 0.0;\n"
    "  for (int k0 = 0; k0 < K; k0 += TS) {\n"
    "    sa[ty][tx] = a[m*K + k0 + tx];\n"
    "    sb[ty][tx] = b[(k0 + ty)*N + n];\n"
    "    barrier();\n"
    "    for (int k = 0; k < TS; k++) s += sa[ty][k] * sb[k][tx];\n"
    "    barrier();\n"
    "  }\n"
    "  c[m*N + n] = s;\n"
    "}\n";

// Register blocking without shared memory: each invocation computes RM rows x
// 4 columns (one vec4 per row), K stepped by 4 with vec4 loads of A and B.
static const char *k_reg =
    "layout(std430, binding=0) readonly buffer BA { vec4 a[]; };\n"
    "#ifdef TEXB\n"
    "uniform highp sampler2D tb;\n"
    "layout(std430, binding=1) readonly buffer BS { vec4 scl[]; };\n"
    "#define LOADB(k, n) texelFetch(tb, ivec2(n, k), 0)\n"
    "#define SCALE(n) scl[n]\n"
    "#else\n"
    "layout(std430, binding=1) readonly buffer BB { vec4 b[]; };\n"
    "#define LOADB(k, n) b[(k)*N4 + (n)]\n"
    "#define SCALE(n) vec4(1.0)\n"
    "#endif\n"
    "layout(std430, binding=2) writeonly buffer BC { vec4 c[]; };\n"
    "void main() {\n"
    "  int n4 = int(gl_GlobalInvocationID.x);\n"
    "  int m = row0 + int(gl_GlobalInvocationID.y) * RM;\n"
    "  int K4 = K >> 2, N4 = N >> 2;\n"
    "  FT acc[RM];\n"
    "  for (int r = 0; r < RM; r++) acc[r] = FT(0.0);\n"
    "  for (int k4 = 0; k4 < K4; k4++) {\n"
    "    int kk = k4 << 2;\n"
    "    FT b0 = FT(LOADB(kk, n4)), b1 = FT(LOADB(kk+1, n4)), b2 = FT(LOADB(kk+2, n4)), b3 = FT(LOADB(kk+3, n4));\n"
    "    for (int r = 0; r < RM; r++) {\n"
    "      FT x = FT(a[(m + r)*K4 + k4]);\n"
    "      acc[r] += x.x*b0 + x.y*b1 + x.z*b2 + x.w*b3;\n"
    "    }\n"
    "  }\n"
    "  for (int r = 0; r < RM; r++) c[(m + r)*N4 + n4] = vec4(acc[r]) * SCALE(n4);\n"
    "}\n";

// Shared-memory tiles plus register blocking: a BM x BN tile of C per work
// group of (BN/4) x (BM/RM) invocations, each computing RM x 4; K in steps of BK.
static const char *k_st =
    "layout(std430, binding=0) readonly buffer BA { vec4 a[]; };\n"
    "#ifdef TEXB\n"
    "uniform highp sampler2D tb;\n"
    "layout(std430, binding=1) readonly buffer BS { vec4 scl[]; };\n"
    "#define LOADB(k, n) texelFetch(tb, ivec2(n, k), 0)\n"
    "#define SCALE(n) scl[n]\n"
    "#else\n"
    "layout(std430, binding=1) readonly buffer BB { vec4 b[]; };\n"
    "#define LOADB(k, n) b[(k)*N4 + (n)]\n"
    "#define SCALE(n) vec4(1.0)\n"
    "#endif\n"
    "layout(std430, binding=2) writeonly buffer BC { vec4 c[]; };\n"
    "shared FT sa[BM][BK/4];\n"   // A tile, rows x K/4 (vec4 along K)
    "shared FT sb[BK][BN/4];\n"   // B tile, K x N/4
    "void main() {\n"
    "  int tx = int(gl_LocalInvocationID.x), ty = int(gl_LocalInvocationID.y);\n"
    "  int tid = ty * (BN/4) + tx;\n"
    "  const int NT = (BN/4) * (BM/RM);\n"
    "  int K4 = K >> 2, N4 = N >> 2;\n"
    "  int mb = row0 + int(gl_WorkGroupID.y) * BM, nb4 = int(gl_WorkGroupID.x) * (BN/4);\n"
    "  FT acc[RM];\n"
    "  for (int r = 0; r < RM; r++) acc[r] = FT(0.0);\n"
    "  for (int k0 = 0; k0 < K; k0 += BK) {\n"
    "    for (int i = tid; i < BM*(BK/4); i += NT) {\n"
    "      int r = i / (BK/4), q = i % (BK/4);\n"
    "      sa[r][q] = FT(a[(mb + r)*K4 + (k0 >> 2) + q]);\n"
    "    }\n"
    "    for (int i = tid; i < BK*(BN/4); i += NT) {\n"
    "      int r = i / (BN/4), q = i % (BN/4);\n"
    "      sb[r][q] = FT(LOADB(k0 + r, nb4 + q));\n"
    "    }\n"
    "    barrier();\n"
    "    for (int kq = 0; kq < BK/4; kq++) {\n"
    "      FT b0 = sb[4*kq][tx], b1 = sb[4*kq+1][tx], b2 = sb[4*kq+2][tx], b3 = sb[4*kq+3][tx];\n"
    "      for (int r = 0; r < RM; r++) {\n"
    "        FT x = sa[ty*RM + r][kq];\n"
    "        acc[r] += x.x*b0 + x.y*b1 + x.z*b2 + x.w*b3;\n"
    "      }\n"
    "    }\n"
    "    barrier();\n"
    "  }\n"
    "  for (int r = 0; r < RM; r++) c[(mb + ty*RM + r)*N4 + nb4 + tx] = vec4(acc[r]) * SCALE(nb4 + tx);\n"
    "}\n";

#define ST(bm, bn, bk, rm) "#define BM " #bm "\n#define BN " #bn "\n#define BK " #bk "\n#define RM " #rm "\n#define FT vec4\n"
#define HALF "precision mediump float;\n"
static const kernel_t kernels[] = {
    {"naive8", 8, 8, 1, 8, 8, NULL, ""},
    {"naive16", 16, 16, 1, 16, 16, NULL, ""},
    {"tile8", 8, 8, 8, 8, 8, NULL, "#define TS 8\n"},
    {"tile16", 16, 16, 16, 16, 16, NULL, "#define TS 16\n"},
    {"r4x4_8x8", 32, 32, 4, 8, 8, NULL, "#define RM 4\n#define FT vec4\n"},
    {"r4x4_16x4", 16, 64, 4, 16, 4, NULL, "#define RM 4\n#define FT vec4\n"},
    {"r4x4_4x16", 64, 16, 4, 4, 16, NULL, "#define RM 4\n#define FT vec4\n"},
    {"r8x4_8x8", 64, 32, 4, 8, 8, NULL, "#define RM 8\n#define FT vec4\n"},
    {"r4x4_8x8h", 32, 32, 4, 8, 8, NULL, "#define RM 4\n#define FT vec4\n" HALF},
    {"st32", 32, 32, 16, 8, 8, NULL, ST(32, 32, 16, 4)},
    {"st64x32", 64, 32, 16, 8, 16, NULL, ST(64, 32, 16, 4)},
    {"st64r8", 64, 64, 16, 16, 8, NULL, ST(64, 64, 16, 8)},
    {"st64r8k32", 64, 64, 32, 16, 8, NULL, ST(64, 64, 32, 8)},
    {"st128r8", 128, 32, 16, 8, 16, NULL, ST(128, 32, 16, 8)},
    {"st64r8h", 64, 64, 16, 16, 8, NULL, ST(64, 64, 16, 8) HALF},
    {"st64x32k32", 64, 32, 32, 8, 16, NULL, ST(64, 32, 32, 4)},
    {"st32k32", 32, 32, 32, 8, 8, NULL, ST(32, 32, 32, 4)},
    {"st128r8k32", 128, 32, 32, 8, 16, NULL, ST(128, 32, 32, 8)},
    {"st64r8k32h", 64, 64, 32, 16, 8, NULL, ST(64, 64, 32, 8) HALF},
    // 16 x 16 invocations: faults the GPU on this driver (see NOTES.md); not run by default
    {"st64", 64, 64, 16, 16, 16, NULL, ST(64, 64, 16, 4)},
#define TX "#define TEXB\n"
    {"r4x4t8", 32, 32, 4, 8, 8, NULL, TX "#define RM 4\n#define FT vec4\n", 8},
    {"r4x4t16", 32, 32, 4, 8, 8, NULL, TX "#define RM 4\n#define FT vec4\n", 16},
    {"r4x4t32", 32, 32, 4, 8, 8, NULL, TX "#define RM 4\n#define FT vec4\n", 32},
    {"r4x4t8h", 32, 32, 4, 8, 8, NULL, TX "#define RM 4\n#define FT vec4\n" HALF, 8},
    {"st64r8k32t8", 64, 64, 32, 16, 8, NULL, TX ST(64, 64, 32, 8), 8},
    {"st64r8k32t16", 64, 64, 32, 16, 8, NULL, TX ST(64, 64, 32, 8), 16},
    {"st64r8k32t32", 64, 64, 32, 16, 8, NULL, TX ST(64, 64, 32, 8), 32},
    {"st64r8k32t8h", 64, 64, 32, 16, 8, NULL, TX ST(64, 64, 32, 8) HALF, 8},
};
#define NKERNELS (int)(sizeof kernels / sizeof kernels[0])

static const char *body_of(const kernel_t *k)
{
    if (!strncmp(k->name, "naive", 5)) return k_naive;
    if (!strncmp(k->name, "tile", 4)) return k_tile;
    if (k->name[0] == 'r') return k_reg;
    return k_st;
}

static GLuint build(const kernel_t *k)
{
    char lsz[96];
    snprintf(lsz, sizeof lsz, "layout(local_size_x=%d, local_size_y=%d) in;\n", k->lx, k->ly);
    const char *src[] = {hdr, k->defs, lsz, body_of(k)};
    GLuint s = p_glCreateShader(GL_COMPUTE_SHADER);
    p_glShaderSource(s, 4, src, NULL);
    p_glCompileShader(s);
    GLint ok;
    char log[4096];
    p_glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        p_glGetShaderInfoLog(s, sizeof log, NULL, log);
        fprintf(stderr, "%s: compile failed:\n%s\n", k->name, log);
        return 0;
    }
    GLuint p = p_glCreateProgram();
    p_glAttachShader(p, s);
    p_glLinkProgram(p);
    p_glDeleteShader(s);
    p_glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        p_glGetProgramInfoLog(p, sizeof log, NULL, log);
        fprintf(stderr, "%s: link failed:\n%s\n", k->name, log);
        return 0;
    }
    return p;
}

static const kernel_t *find_kernel(const char *n)
{
    for (int i = 0; i < NKERNELS; i++)
        if (!strcmp(kernels[i].name, n)) return &kernels[i];
    return NULL;
}

static int rup(int x, int m) { return (x + m - 1) / m * m; }

// ---- one shape ----
typedef struct {
    int M, K, N;     // real
    int Mp, Kp, Np;  // padded (multiple of 64 / 64 / 16)
    float *a, *b, *c;
    GLuint buf[3];
} prob_t;

static uint32_t rng = 12345;
static float frand(void)
{
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xffff) / 32768.0f - 1.0f;
}

static void prob_init(prob_t *p, int M, int K, int N)
{
    p->M = M, p->K = K, p->N = N;
    p->Mp = rup(M, 64), p->Kp = rup(K, 16), p->Np = rup(N, 64);
    p->a = calloc((size_t)p->Mp * p->Kp, 4);
    p->b = calloc((size_t)p->Kp * p->Np, 4);
    p->c = calloc((size_t)p->Mp * p->Np, 4);
    if (!p->a || !p->b || !p->c) die("out of memory");
    for (int i = 0; i < M; i++)
        for (int k = 0; k < K; k++) p->a[(size_t)i * p->Kp + k] = frand();
    for (int k = 0; k < K; k++)
        for (int j = 0; j < N; j++) p->b[(size_t)k * p->Np + j] = frand();
    p_glGenBuffers(3, p->buf);
    size_t sz[3] = {(size_t)p->Mp * p->Kp * 4, (size_t)p->Kp * p->Np * 4, (size_t)p->Mp * p->Np * 4};
    for (int i = 0; i < 3; i++) {
        p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, p->buf[i]);
        p_glBufferData(GL_SHADER_STORAGE_BUFFER, sz[i], NULL, i == 2 ? GL_DYNAMIC_READ : GL_DYNAMIC_DRAW);
        p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, i, p->buf[i]);
    }
    p_glFinish();
}

static double t_upload_a, t_upload_b, t_download_c;

static void upload(prob_t *p)
{
    double t0 = now();
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, p->buf[0]);
    p_glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, (size_t)p->Mp * p->Kp * 4, p->a);
    p_glFinish();
    double t1 = now();
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, p->buf[1]);
    p_glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, (size_t)p->Kp * p->Np * 4, p->b);
    p_glFinish();
    double t2 = now();
    t_upload_a = t1 - t0, t_upload_b = t2 - t1;
}

static void download(prob_t *p)
{
    double t0 = now();
    size_t sz = (size_t)p->Mp * p->Np * 4;
    p_glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, p->buf[2]);
    void *m = p_glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, sz, GL_MAP_READ_BIT);
    if (!m) die("glMapBufferRange");
    memcpy(p->c, m, sz);
    p_glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
    t_download_c = now() - t0;
}

// Rows per dispatch so one dispatch is at most ~chunk_gflop of work.
static double chunk_gflop = 0.25;

static void dispatch(const kernel_t *k, GLuint prog, prob_t *p)
{
    p_glUseProgram(prog);
    p_glUniform1i(p_glGetUniformLocation(prog, "M"), p->Mp);
    p_glUniform1i(p_glGetUniformLocation(prog, "N"), p->Np);
    p_glUniform1i(p_glGetUniformLocation(prog, "K"), p->Kp);
    GLint lrow = p_glGetUniformLocation(prog, "row0");
    double per_row = 2.0 * p->Np * p->Kp;
    double cg = chunk_gflop;
    if (!strncmp(k->name, "naive", 5) || !strncmp(k->name, "tile", 4)) cg /= 16;  // ~1 GFLOP/s kernels
    int rows = (int)(cg * 1e9 / per_row) / k->bm * k->bm;
    if (rows < k->bm) rows = k->bm;
    if (rows > p->Mp) rows = p->Mp;
    for (int r0 = 0; r0 < p->Mp; r0 += rows) {
        int nr = p->Mp - r0 < rows ? p->Mp - r0 : rows;
        p_glUniform1i(lrow, r0);
        p_glDispatchCompute(p->Np / k->bn, nr / k->bm, 1);
        p_glFlush();  // one submission per chunk, so the hangcheck sees progress
    }
}

// Reference on sampled rows (double accumulation): max |err| and max |ref|.
static void check(prob_t *p, double *maxerr, double *maxref)
{
    *maxerr = 0, *maxref = 0;
    int nrows = p->M < 24 ? p->M : 24;
    for (int s = 0; s < nrows; s++) {
        int i = (int)((long)s * (p->M - 1) / (nrows > 1 ? nrows - 1 : 1));
        for (int j = 0; j < p->N; j++) {
            double acc = 0;
            for (int k = 0; k < p->K; k++) acc += (double)p->a[(size_t)i * p->Kp + k] * p->b[(size_t)k * p->Np + j];
            double e = fabs(acc - p->c[(size_t)i * p->Np + j]);
            if (e > *maxerr) *maxerr = e;
            if (fabs(acc) > *maxref) *maxref = fabs(acc);
        }
    }
}

static uint16_t f2h(float f)
{
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000, e = (x >> 23) & 0xff, m = x & 0x7fffff;
    int he = (int)e - 127 + 15;
    if (e == 0 || he <= 0) return sign;  // inputs here are never subnormal-small
    if (he >= 31) return sign | 0x7c00;
    uint32_t h = sign | (he << 10) | (m >> 13);
    if ((m & 0x1fff) > 0x1000 || ((m & 0x1fff) == 0x1000 && (h & 1))) h++;
    return h;
}
static float h2f(uint16_t h)
{
    uint32_t sign = (uint32_t)(h & 0x8000) << 16, e = (h >> 10) & 0x1f, m = h & 0x3ff, x;
    if (e == 0) x = sign;
    else x = sign | ((e - 15 + 127) << 23) | (m << 13);
    float f;
    memcpy(&f, &x, 4);
    return f;
}

// B as a K x (N/4) RGBA texture (one texel = 4 columns) plus a per-column
// scale SSBO. For 8-bit, each column is quantised symmetrically to int8 with
// scale max|b|/127, the stand-in for int8 weights. bref receives the values
// the GPU actually sees, so the error check measures the arithmetic only.
static GLuint tex_b, scl_buf;
static double t_upload_tex;
static void make_tex(prob_t *p, int fmt, float *bref)
{
    int w = p->Np / 4, h = p->Kp;
    size_t n = (size_t)p->Kp * p->Np;
    float *scl = malloc(p->Np * 4);
    void *data = malloc(n * 4);
    for (int j = 0; j < p->Np; j++) {
        float mx = 0;
        for (int k = 0; k < p->Kp; k++) mx = fmaxf(mx, fabsf(p->b[(size_t)k * p->Np + j]));
        scl[j] = fmt == 8 ? (mx > 0 ? mx / 127.0f : 1.0f) : 1.0f;
    }
    for (size_t i = 0; i < n; i++) {
        float v = p->b[i];
        int j = i % p->Np;
        if (fmt == 8) {
            int q = (int)lrintf(v / scl[j]);
            q = q > 127 ? 127 : q < -127 ? -127 : q;
            ((int8_t *)data)[i] = q;
            bref[i] = q * scl[j];  // snorm: q/127 in the shader, times scale*127
        } else if (fmt == 16) {
            ((uint16_t *)data)[i] = f2h(v);
            bref[i] = h2f(f2h(v));
        } else {
            ((float *)data)[i] = v;
            bref[i] = v;
        }
    }
    if (fmt == 8)
        for (int j = 0; j < p->Np; j++) scl[j] *= 127.0f;
    GLenum ifmt = fmt == 8 ? GL_RGBA8_SNORM : fmt == 16 ? GL_RGBA16F : GL_RGBA32F;
    GLenum type = fmt == 8 ? GL_BYTE : fmt == 16 ? GL_HALF_FLOAT : GL_FLOAT;
    if (!tex_b) p_glGenTextures(1, &tex_b);
    else { p_glDeleteTextures(1, &tex_b); p_glGenTextures(1, &tex_b); }
    p_glActiveTexture(GL_TEXTURE0);
    p_glBindTexture(GL_TEXTURE_2D, tex_b);
    p_glTexStorage2D(GL_TEXTURE_2D, 1, ifmt, w, h);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    p_glFinish();
    double t0 = now();
    p_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, type, data);
    p_glFinish();
    t_upload_tex = now() - t0;
    if (!scl_buf) p_glGenBuffers(1, &scl_buf);
    p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, scl_buf);
    p_glBufferData(GL_SHADER_STORAGE_BUFFER, p->Np * 4, scl, GL_STATIC_DRAW);
    free(scl);
    free(data);
    if (p_glGetError() != GL_NO_ERROR) die("texture setup failed");
}

static void bench(int M, int K, int N, int nk, char **names)
{
    prob_t p;
    prob_init(&p, M, K, N);
    upload(&p);
    upload(&p);  // second one is the steady-state number
    double flop = 2.0 * M * N * K;
    for (int i = 0; i < nk; i++) {
        const kernel_t *k = find_kernel(names[i]);
        if (!k) { fprintf(stderr, "unknown kernel %s\n", names[i]); continue; }
        GLuint prog = build(k);
        if (!prog) { printf("%-10s M=%d K=%d N=%d  FAILED to build\n", k->name, M, K, N); continue; }
        memset(p.c, 0, (size_t)p.Mp * p.Np * 4);
        float *bsave = p.b, *bref = NULL;
        double upb = t_upload_b;
        if (k->texb) {
            bref = malloc((size_t)p.Kp * p.Np * 4);
            make_tex(&p, k->texb, bref);
            p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, scl_buf);
            p_glUseProgram(prog);
            p_glUniform1i(p_glGetUniformLocation(prog, "tb"), 0);
            upb = t_upload_tex;
        } else {
            p_glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, p.buf[1]);
        }
        {   // clear the GPU copy of C so a kernel that does not run cannot pass the check
            p_glBindBuffer(GL_SHADER_STORAGE_BUFFER, p.buf[2]);
            p_glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, (size_t)p.Mp * p.Np * 4, p.c);
        }
        dispatch(k, prog, &p);  // warm-up (shader upload, first-use costs)
        p_glFinish();
        if (p_glGetError() != GL_NO_ERROR) { printf("%-10s GL error\n", k->name); continue; }
        // Repeat until at least 0.5 s (at most 50 runs).
        int reps = 0;
        double t0 = now(), t;
        do {
            dispatch(k, prog, &p);
            p_glFinish();
            reps++;
            t = now() - t0;
        } while (t < 0.5 && reps < 50);
        double tk = t / reps;
        GLenum ge = p_glGetError();
        if (ge != GL_NO_ERROR) printf("%-10s GL error 0x%x after timing\n", k->name, ge);
        download(&p);
        download(&p);
        double err, ref, err32 = 0, ref32;
        if (bref) {
            check(&p, &err32, &ref32);  // against FP32 weights: includes the quantisation
            p.b = bref;
        }
        check(&p, &err, &ref);  // against the weights the GPU actually saw
        p.b = bsave;
        free(bref);
        if (!k->texb) err32 = err;
        double t_all = t_upload_a + upb + tk + t_download_c;
        double t_res = t_upload_a + tk + t_download_c;  // B (weights) resident
        if (err > 0.5 * ref) {  // C left at zero: the dispatches faulted (see dmesg)
            printf("%-10s M=%-5d K=%-5d N=%-5d INVALID: output not written (GPU fault)\n", k->name, M, K, N);
            p_glDeleteProgram(prog);
            continue;
        }
        printf("%-10s M=%-5d K=%-5d N=%-5d kernel %8.3f ms %6.2f GFLOP/s | +copies %6.2f GFLOP/s "
               "(upA %.2f upB %.2f dnC %.2f ms) | B resident %6.2f GFLOP/s | B read %5.2f GB/s | maxerr %.2e vsFP32 %.2e (max|ref| %.1f) reps %d\n",
               k->name, M, K, N, tk * 1e3, flop / tk * 1e-9, flop / t_all * 1e-9, t_upload_a * 1e3,
               upb * 1e3, t_download_c * 1e3, flop / t_res * 1e-9,
               (double)K * N * (k->texb ? k->texb / 8 : 4) / tk * 1e-9, err, err32, ref, reps);
        fflush(stdout);
        p_glDeleteProgram(prog);
    }
}

static void soak(double secs, int M, int K, int N, const char *name)
{
    prob_t p;
    prob_init(&p, M, K, N);
    upload(&p);
    const kernel_t *k = find_kernel(name);
    if (!k) die("unknown kernel");
    GLuint prog = build(k);
    if (!prog) die("build");
    double flop = 2.0 * M * N * K, t0 = now(), last = t0;
    long reps = 0, last_reps = 0;
    while (now() - t0 < secs) {
        dispatch(k, prog, &p);
        p_glFinish();
        reps++;
        double t = now();
        if (t - last >= 5.0) {
            printf("soak t=%5.1f s  %6.2f GFLOP/s\n", t - t0, flop * (reps - last_reps) / (t - last) * 1e-9);
            fflush(stdout);
            last = t, last_reps = reps;
        }
    }
    printf("soak total %.1f s, %ld runs, mean %.2f GFLOP/s\n", now() - t0, reps, flop * reps / (now() - t0) * 1e-9);
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    printf("soak host CPU: user %.2f s sys %.2f s\n", ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6,
           ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s info | bench M K N kernel... | soak SECS M K N kernel\n", argv[0]);
        return 2;
    }
    const char *cg = getenv("GLES_SGEMM_CHUNK_GFLOP");
    if (cg) chunk_gflop = atof(cg);
    gl_init();
    if (!strcmp(argv[1], "info")) info();
    else if (!strcmp(argv[1], "bench") && argc >= 6)
        bench(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), argc - 5, argv + 5);
    else if (!strcmp(argv[1], "soak") && argc == 7)
        soak(atof(argv[2]), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]), argv[6]);
    else {
        fprintf(stderr, "bad arguments\n");
        return 2;
    }
    p_eglTerminate(dpy);
    return 0;
}
