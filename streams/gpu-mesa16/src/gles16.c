// gles16: GL_EXT_shader_16bit_storage on the Adreno 506 (GLES 3.1 compute).
//
//   gles16 info                       context, 16-bit storage extension
//   gles16 test                       correctness tests of the extension
//   gles16 gemm M K N [variant...]    C = A·B, timed, error vs FP64 reference
//   gles16 conv C L KW [variant...]   conv1d, C in = C out channels, length L,
//                                     kernel KW, "same" padding, as implicit GEMM
//
// GEMM variants (tile 64x64, BK 32, 8 rows x vec4 per invocation, 128
// invocations: the st64r8k32 kernel of streams/gpu-compute):
//   f32   A, B FP32 in SSBOs, FP32 math                 (the 14.4 GFLOP/s baseline)
//   m32   A, B FP32 in SSBOs, mediump (FP16) math       (the 0.75x result)
//   h32   A, B FP16 in SSBOs, FP32 math and accumulation
//   h16   A, B FP16 in SSBOs, FP16 math and accumulation
//   hmix  A, B FP16 in SSBOs, FP16 products summed over each 32-long K block,
//         FP32 accumulation across blocks
// C is always FP32. GFLOP/s counts 2*M*N*K. Timing is wall clock around
// glFinish for the kernel only, repeated for >= 0.5 s; work is split into
// dispatches of <= 0.05 GFLOP (each flushed) for the msm hangcheck: at the
// lowest devfreq step (19.2 MHz) a 0.25 GFLOP dispatch takes longer than 0.5 s.
// Error: max |C - ref| on sampled rows, ref in FP64 from the FP32 inputs
// ("vs fp32") and from the FP16-rounded inputs ("vs fp16 in").
#include "glctx.h"
#include <math.h>
#include <stdarg.h>
#include <stdint.h>

#define GL_EXT_SHADER_16BIT_STORAGE "GL_EXT_shader_16bit_storage"

// ---- FP16 helpers (round to nearest even; no subnormal outputs needed) ----
static uint16_t f2h(float f)
{
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000, e = (x >> 23) & 0xff, m = x & 0x7fffff;
    int he = (int)e - 127 + 15;
    if (e == 255) return sign | 0x7c00 | (m ? 0x200 : 0);
    if (he <= 0) {  // subnormal or zero
        if (he < -10) return sign;
        m |= 0x800000;
        int sh = 14 - he;
        uint32_t h = m >> sh, rem = m & ((1u << sh) - 1), half = 1u << (sh - 1);
        if (rem > half || (rem == half && (h & 1))) h++;
        return sign | h;
    }
    if (he >= 31) return sign | 0x7c00;
    uint32_t h = sign | (he << 10) | (m >> 13);
    if ((m & 0x1fff) > 0x1000 || ((m & 0x1fff) == 0x1000 && (h & 1))) h++;
    return h;
}
static float h2f(uint16_t h)
{
    uint32_t sign = (uint32_t)(h & 0x8000) << 16, e = (h >> 10) & 0x1f, m = h & 0x3ff, x;
    if (e == 0) {
        float f = ldexpf((float)m, -24);
        return sign ? -f : f;
    }
    if (e == 31) x = sign | 0x7f800000 | (m << 13);
    else x = sign | ((e - 15 + 127) << 23) | (m << 13);
    float f;
    memcpy(&f, &x, 4);
    return f;
}

static uint32_t rng = 12345;
static float frand(void)
{
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xffff) / 32768.0f - 1.0f;
}

static void info(void)
{
    printf("GL_RENDERER     %s\n", p_glGetString(GL_RENDERER));
    printf("GL_VERSION      %s\n", p_glGetString(GL_VERSION));
    printf("GL_SHADING_LANGUAGE_VERSION %s\n", p_glGetString(GL_SHADING_LANGUAGE_VERSION));
    static const char *want[] = {GL_EXT_SHADER_16BIT_STORAGE, "GL_EXT_shader_explicit_arithmetic_types_float16",
                                 "GL_AMD_gpu_shader_half_float"};
    for (unsigned i = 0; i < sizeof want / sizeof want[0]; i++)
        printf("  %-48s %s\n", want[i], has_ext(want[i]) ? "yes" : "no");
}

// ---- correctness tests ----
static int fails, passes;
static void result(const char *name, int ok, const char *fmt, ...)
{
    printf("%-34s %s", name, ok ? "PASS" : "FAIL");
    if (fmt) {
        va_list ap;
        va_start(ap, fmt);
        printf("  ");
        vprintf(fmt, ap);
        va_end(ap);
    }
    printf("\n");
    if (ok) passes++;
    else fails++;
}

#define HDR "#version 310 es\n#extension GL_EXT_shader_16bit_storage : require\n"

// Run src with buffers in (binding 0), out (binding 1), optional UBO (binding 0).
static int run(const char *src, const void *in, size_t in_sz, void *out, size_t out_sz,
               const void *ubo, size_t ubo_sz, int groups)
{
    GLuint p = make_prog(src, 0);
    if (!p) return 0;
    GLuint bi = make_ssbo(0, in_sz, in);
    GLuint bo = make_ssbo(1, out_sz, out);
    GLuint bu = 0;
    if (ubo) {
        p_glGenBuffers(1, &bu);
        p_glBindBuffer(GL_UNIFORM_BUFFER, bu);
        p_glBufferData(GL_UNIFORM_BUFFER, ubo_sz, ubo, GL_STATIC_DRAW);
        p_glBindBufferBase(GL_UNIFORM_BUFFER, 0, bu);
    }
    p_glUseProgram(p);
    p_glDispatchCompute(groups, 1, 1);
    p_glMemoryBarrier(GL_ALL_BARRIER_BITS);
    p_glFinish();
    read_ssbo(bo, out_sz, out);
    p_glDeleteBuffers(1, &bi);
    p_glDeleteBuffers(1, &bo);
    if (bu) p_glDeleteBuffers(1, &bu);
    p_glDeleteProgram(p);
    return p_glGetError() == GL_NO_ERROR;
}

static int compiles(const char *src)
{
    GLuint p = make_prog(src, 1);
    if (p) p_glDeleteProgram(p);
    return p != 0;
}

static void tests(void)
{
    enum { N = 256 };
    static uint16_t h_in[N], h_out[N];
    static float f_out[N];
    for (int i = 0; i < N; i++) h_in[i] = f2h(frand() * 4.0f);
    h_in[0] = f2h(65504.0f), h_in[1] = f2h(-0.0f), h_in[2] = 0x0001 /* subnormal */, h_in[3] = 0x7c00;

    // 1. scalar float16_t load -> float -> store as float (no arithmetic).
    {
        const char *s = HDR "layout(local_size_x = 64) in;\n"
            "layout(std430, binding = 0) readonly buffer I { float16_t a[]; };\n"
            "layout(std430, binding = 1) writeonly buffer O { float b[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x; b[i] = float(a[i]); }\n";
        memset(f_out, 0, sizeof f_out);
        int ok = run(s, h_in, sizeof h_in, f_out, sizeof f_out, NULL, 0, N / 64), bad = 0;
        for (int i = 0; i < N; i++) bad += memcmp(&f_out[i], &(float){h2f(h_in[i])}, 4) != 0;
        result("load float16_t -> float", ok && !bad, "%d/%d mismatches", bad, N);
    }
    // 2. float -> float16_t store (rounding), every element.
    {
        static float f_in[N];
        for (int i = 0; i < N; i++) f_in[i] = frand() * 1000.0f;
        const char *s = HDR "layout(local_size_x = 64) in;\n"
            "layout(std430, binding = 0) readonly buffer I { float a[]; };\n"
            "layout(std430, binding = 1) writeonly buffer O { float16_t b[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x; b[i] = float16_t(a[i]); }\n";
        memset(h_out, 0xee, sizeof h_out);
        int ok = run(s, f_in, sizeof f_in, h_out, sizeof h_out, NULL, 0, N / 64), bad = 0, ulp1 = 0;
        for (int i = 0; i < N; i++) {
            int d = abs((int)h_out[i] - (int)f2h(f_in[i]));
            bad += d > 1;
            ulp1 += d == 1;
        }
        result("store float -> float16_t", ok && !bad, "%d off by > 1 ulp, %d by 1 ulp (rounding mode)", bad, ulp1);
    }
    // 3. f16vec4 / f16vec2 copy with arithmetic in FP32, and odd scalar stores.
    {
        const char *s = HDR "layout(local_size_x = 16) in;\n"
            "layout(std430, binding = 0) readonly buffer I { f16vec4 a[]; };\n"
            "layout(std430, binding = 1) buffer O { f16vec2 b[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x;\n"
            "  vec4 v = vec4(a[i]) * 2.0;\n"
            "  b[2u*i] = f16vec2(v.xy); b[2u*i+1u] = f16vec2(v.zw); }\n";
        memset(h_out, 0xee, sizeof h_out);
        int ok = run(s, h_in, sizeof h_in, h_out, sizeof h_out, NULL, 0, N / 4 / 16), bad = 0;
        for (int i = 4; i < N; i++) bad += h_out[i] != f2h(2.0f * h2f(h_in[i]));
        result("f16vec4 load, f16vec2 store", ok && !bad, "%d/%d mismatches", bad, N - 4);
    }
    {
        const char *s = HDR "layout(local_size_x = 64) in;\n"
            "layout(std430, binding = 0) readonly buffer I { float16_t a[]; };\n"
            "layout(std430, binding = 1) buffer O { float16_t b[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x;\n"
            "  if ((i & 1u) == 1u) b[i] = a[i - 1u]; }\n";
        memset(h_out, 0xee, sizeof h_out);
        int ok = run(s, h_in, sizeof h_in, h_out, sizeof h_out, NULL, 0, N / 64), bad = 0;
        for (int i = 0; i < N; i++) bad += h_out[i] != ((i & 1) ? h_in[i - 1] : 0xeeee);
        result("odd-index 16-bit stores, no clobber", ok && !bad, "%d/%d mismatches", bad, N);
    }
    // 4. int16_t / uint16_t: sign and zero extension, truncation.
    {
        static int16_t i_in[N];
        static int32_t i_out[2 * N];
        for (int i = 0; i < N; i++) i_in[i] = (int16_t)(i * 517 - 30000);
        const char *s = HDR "layout(local_size_x = 64) in;\n"
            "layout(std430, binding = 0) readonly buffer I { int16_t a[]; };\n"
            "layout(std430, binding = 1) writeonly buffer O { int b[]; };\n"
            "layout(std430, binding = 0) readonly buffer J { uint16_t u[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x;\n"
            "  b[2u*i] = int(a[i]); b[2u*i+1u] = int(uint(u[i])); }\n";
        int ok = run(s, i_in, sizeof i_in, i_out, sizeof i_out, NULL, 0, N / 64), bad = 0;
        for (int i = 0; i < N; i++)
            bad += i_out[2 * i] != i_in[i] || i_out[2 * i + 1] != (uint16_t)i_in[i];
        result("int16_t/uint16_t load, extend", ok && !bad, "%d/%d mismatches", bad, N);

        static int32_t w_in[N];
        static uint16_t w_out[N];
        for (int i = 0; i < N; i++) w_in[i] = i * 123457 - 7;
        const char *t = HDR "layout(local_size_x = 64) in;\n"
            "layout(std430, binding = 0) readonly buffer I { int a[]; };\n"
            "layout(std430, binding = 1) writeonly buffer O { int16_t b[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x; b[i] = int16_t(a[i]); }\n";
        ok = run(t, w_in, sizeof w_in, w_out, sizeof w_out, NULL, 0, N / 64), bad = 0;
        for (int i = 0; i < N; i++) bad += w_out[i] != (uint16_t)w_in[i];
        result("int -> int16_t store (truncate)", ok && !bad, "%d/%d mismatches", bad, N);
    }
    // 5. std430 struct mixing 16- and 32-bit members.
    {
        // struct S { float16_t h; float f; f16vec3 v; uint16_t u; }: h@0 f@4 v@8 u@14, stride 16
        static uint8_t in[16 * 64];
        static float out[6 * 64];
        for (int i = 0; i < 64; i++) {
            uint8_t *e = in + 16 * i;
            uint16_t h = f2h(i * 0.5f), v0 = f2h(-i), v1 = f2h(i * 0.25f), v2 = f2h(100 + i), u = 60000 + i;
            float f = i * 3.0f;
            memcpy(e, &h, 2), memcpy(e + 4, &f, 4), memcpy(e + 8, &v0, 2), memcpy(e + 10, &v1, 2);
            memcpy(e + 12, &v2, 2), memcpy(e + 14, &u, 2);
        }
        const char *s = HDR "layout(local_size_x = 64) in;\n"
            "struct S { float16_t h; float f; f16vec3 v; uint16_t u; };\n"
            "layout(std430, binding = 0) readonly buffer I { S s[]; };\n"
            "layout(std430, binding = 1) writeonly buffer O { float o[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x;\n"
            "  o[6u*i] = float(s[i].h); o[6u*i+1u] = s[i].f; vec3 v = vec3(s[i].v);\n"
            "  o[6u*i+2u] = v.x; o[6u*i+3u] = v.y; o[6u*i+4u] = v.z; o[6u*i+5u] = float(uint(s[i].u)); }\n";
        int ok = run(s, in, sizeof in, out, sizeof out, NULL, 0, 1), bad = 0;
        for (int i = 0; i < 64; i++) {
            float e[6] = {i * 0.5f, i * 3.0f, -i, i * 0.25f, 100 + i, 60000 + i};
            for (int j = 0; j < 6; j++) bad += out[6 * i + j] != e[j];
        }
        result("std430 struct with 16-bit members", ok && !bad, "%d/%d mismatches", bad, 6 * 64);
    }
    // 6. UBO (std140) with f16vec4 array: array stride is 16 bytes in std140.
    {
        static uint16_t ubo[8 * 16];
        static float out[4 * 16];
        memset(ubo, 0, sizeof ubo);
        for (int i = 0; i < 16; i++)
            for (int j = 0; j < 4; j++) ubo[8 * i + j] = f2h(i + j * 0.125f);
        const char *s = HDR "layout(local_size_x = 16) in;\n"
            "layout(std140, binding = 0) uniform U { f16vec4 w[16]; };\n"
            "layout(std430, binding = 0) readonly buffer I { float unused[]; };\n"
            "layout(std430, binding = 1) writeonly buffer O { vec4 o[]; };\n"
            "void main() { uint i = gl_GlobalInvocationID.x; o[i] = vec4(w[i]); }\n";
        float dummy[4] = {0};
        int ok = run(s, dummy, sizeof dummy, out, sizeof out, ubo, sizeof ubo, 1), bad = 0;
        for (int i = 0; i < 16; i++)
            for (int j = 0; j < 4; j++) bad += out[4 * i + j] != i + j * 0.125f;
        result("std140 UBO f16vec4[] load", ok && !bad, "%d/%d mismatches", bad, 64);

        // std430-like packing in a UBO is not possible; also check a scalar f16 member pair.
        static uint16_t ubo2[8];
        memset(ubo2, 0, sizeof ubo2);
        ubo2[0] = f2h(1.5f), ubo2[1] = f2h(-2.25f), ubo2[2] = 0x8001;  // h0@0 h1@2 u@4
        const char *t = HDR "layout(local_size_x = 1) in;\n"
            "layout(std140, binding = 0) uniform U { float16_t h0; float16_t h1; int16_t u; };\n"
            "layout(std430, binding = 0) readonly buffer I { float unused[]; };\n"
            "layout(std430, binding = 1) writeonly buffer O { vec4 o[]; };\n"
            "void main() { o[0] = vec4(float(h0), float(h1), float(int(u)), 0.0); }\n";
        ok = run(t, dummy, sizeof dummy, out, 16, ubo2, sizeof ubo2, 1);
        bad = out[0] != 1.5f || out[1] != -2.25f || out[2] != (float)(int16_t)0x8001;
        result("std140 UBO packed 16-bit scalars", ok && !bad, "got %g %g %g", out[0], out[1], out[2]);
    }
    // 7. Compile-time rules.
    static const struct { const char *name, *src; int ok; } ct[] = {
        {"accept: struct in buffer",
         HDR "layout(local_size_x=1) in; struct S { float16_t a; i16vec2 b; u16vec4 c; };\n"
             "layout(std430, binding=0) buffer B { f16vec4 v; S s[]; };\n"
             "void main() { s[0].a = float16_t(float(s[1].a)); s[0].b = s[1].b; v = f16vec4(vec4(v)); }\n", 1},
        {"reject: float16_t local",
         HDR "layout(local_size_x=1) in; layout(std430, binding=0) buffer B { float16_t x; };\n"
             "void main() { float16_t t = x; x = t; }\n", 0},
        {"reject: arithmetic on float16_t",
         HDR "layout(local_size_x=1) in; layout(std430, binding=0) buffer B { float16_t x, y; };\n"
             "void main() { x = x * y; }\n", 0},
        {"reject: int16_t(float)",
         HDR "layout(local_size_x=1) in; layout(std430, binding=0) buffer B { int16_t x; float f; };\n"
             "void main() { x = int16_t(f); }\n", 0},
        {"reject: float16_t without #extension",
         "#version 310 es\nlayout(local_size_x=1) in; layout(std430, binding=0) buffer B { float16_t x; };\n"
         "void main() { }\n", 0},
        {"reject: shared float16_t",
         HDR "layout(local_size_x=1) in; shared float16_t s[4];\n"
             "layout(std430, binding=0) buffer B { float16_t x; };\n"
             "void main() { s[0] = x; x = s[0]; }\n", 0},
    };
    for (unsigned i = 0; i < sizeof ct / sizeof ct[0]; i++) {
        int c = compiles(ct[i].src);
        result(ct[i].name, c == ct[i].ok, NULL);
    }
    printf("%d passed, %d failed\n", passes, fails);
}

// ---- GEMM / conv kernels ----
typedef struct {
    const char *name;
    int h16;          // A/B stored as FP16
    const char *defs;
} variant_t;

static const variant_t variants[] = {
    {"f32", 0, "#define ST vec4\n#define CT highp vec4\n#define AT highp vec4\n"},
    {"m32", 0, "#define ST vec4\n#define CT mediump vec4\n#define AT mediump vec4\n"},
    {"h32", 1, "#define ST f16vec4\n#define CT highp vec4\n#define AT highp vec4\n"},
    {"h16", 1, "#define ST f16vec4\n#define CT mediump vec4\n#define AT mediump vec4\n"},
    {"hmix", 1, "#define ST f16vec4\n#define CT mediump vec4\n#define AT highp vec4\n#define MIX 1\n"},
};
#define NVAR (int)(sizeof variants / sizeof variants[0])

static const char *k_hdr =
    "#version 310 es\n"
    "#extension GL_EXT_shader_16bit_storage : enable\n"
    "precision highp float;\nprecision highp int;\n"
    "uniform int M, N, K, row0, col0;\n";

// Shared-memory tiles plus register blocking (see streams/gpu-compute, st64r8k32).
// LOADB(k, n4) gives 4 consecutive columns of B at row k.
static const char *k_body =
    "layout(std430, binding=0) readonly buffer BA { ST a[]; };\n"
    "#ifdef CONV\n"
    "#define S1 SCALAR\n"
    "layout(std430, binding=1) readonly buffer BX { S1 x[]; };\n"
    "uniform int LP;\n"  // padded input row length
    "CT loadb(int k, int n4) {\n"
    "  int ci = k / KW, kw = k - ci * KW, o = ci * LP + 4 * n4 + kw;\n"
    "  return vec4(float(x[o]), float(x[o + 1]), float(x[o + 2]), float(x[o + 3]));\n"
    "}\n"
    "#define LOADB(k, n4) loadb(k, n4)\n"
    "#else\n"
    "layout(std430, binding=1) readonly buffer BB { ST b[]; };\n"
    "#define LOADB(k, n4) vec4(b[(k)*N4 + (n4)])\n"
    "#endif\n"
    "layout(std430, binding=2) writeonly buffer BC { vec4 c[]; };\n"
    "shared CT sa[BM][BK/4];\n"
    "shared CT sb[BK][BN/4];\n"
    "void main() {\n"
    "  int tx = int(gl_LocalInvocationID.x), ty = int(gl_LocalInvocationID.y);\n"
    "  int tid = ty * (BN/4) + tx;\n"
    "  const int NT = (BN/4) * (BM/RM);\n"
    "  int K4 = K >> 2, N4 = N >> 2;\n"
    "  int mb = row0 + int(gl_WorkGroupID.y) * BM, nb4 = (col0 >> 2) + int(gl_WorkGroupID.x) * (BN/4);\n"
    "  AT acc[RM];\n"
    "  for (int r = 0; r < RM; r++) acc[r] = vec4(0.0);\n"
    "  for (int k0 = 0; k0 < K; k0 += BK) {\n"
    "    for (int i = tid; i < BM*(BK/4); i += NT) {\n"
    "      int r = i / (BK/4), q = i % (BK/4);\n"
    "      sa[r][q] = vec4(a[(mb + r)*K4 + (k0 >> 2) + q]);\n"
    "    }\n"
    "    for (int i = tid; i < BK*(BN/4); i += NT) {\n"
    "      int r = i / (BN/4), q = i % (BN/4);\n"
    "      sb[r][q] = LOADB(k0 + r, nb4 + q);\n"
    "    }\n"
    "    barrier();\n"
    "#ifdef MIX\n"
    "    CT part[RM];\n"
    "    for (int r = 0; r < RM; r++) part[r] = vec4(0.0);\n"
    "#define DST part\n"
    "#else\n"
    "#define DST acc\n"
    "#endif\n"
    "    for (int kq = 0; kq < BK/4; kq++) {\n"
    "      CT b0 = sb[4*kq][tx], b1 = sb[4*kq+1][tx], b2 = sb[4*kq+2][tx], b3 = sb[4*kq+3][tx];\n"
    "      for (int r = 0; r < RM; r++) {\n"
    "        CT xx = sa[ty*RM + r][kq];\n"
    "        DST[r] += xx.x*b0 + xx.y*b1 + xx.z*b2 + xx.w*b3;\n"
    "      }\n"
    "    }\n"
    "#ifdef MIX\n"
    "    for (int r = 0; r < RM; r++) acc[r] += vec4(part[r]);\n"
    "#endif\n"
    "    barrier();\n"
    "  }\n"
    "  for (int r = 0; r < RM; r++) c[(mb + ty*RM + r)*N4 + nb4 + tx] = vec4(acc[r]);\n"
    "}\n";

// Tile shape: RM rows x vec4 per invocation, 16 x LY invocations, so the C
// tile is BM = LY*RM rows by BN = 64 columns (GLES16_RM, GLES16_LY; default 8, 8).
static int RM = 8, LY = 8, BM = 64;

static GLuint build(const variant_t *v, const char *extra)
{
    char tile[160];
    snprintf(tile, sizeof tile, "#define BM %d\n#define BN 64\n#define BK 32\n#define RM %d\n"
             "layout(local_size_x = 16, local_size_y = %d) in;\n", BM, RM, LY);
    size_t n = strlen(k_hdr) + strlen(tile) + strlen(v->defs) + strlen(extra) + strlen(k_body) + 1;
    char *s = malloc(n);
    snprintf(s, n, "%s%s%s%s%s", k_hdr, tile, v->defs, extra, k_body);
    GLuint p = make_prog(s, 0);
    free(s);
    return p;
}

static const variant_t *find_variant(const char *n)
{
    for (int i = 0; i < NVAR; i++)
        if (!strcmp(variants[i].name, n)) return &variants[i];
    return NULL;
}

static int rup(int x, int m) { return (x + m - 1) / m * m; }
static double chunk_gflop = 0.05;

// Dispatch an Mp x Np output in chunks of at most chunk_gflop: whole BM-row
// bands when they fit, else BM-row bands split into column blocks (at least
// one 64-column tile). Each chunk is flushed as its own submission.
static void dispatch(GLuint prog, int Mp, int Np, int Kp, int unused)
{
    p_glUseProgram(prog);
    p_glUniform1i(p_glGetUniformLocation(prog, "M"), Mp);
    p_glUniform1i(p_glGetUniformLocation(prog, "N"), Np);
    p_glUniform1i(p_glGetUniformLocation(prog, "K"), Kp);
    GLint lrow = p_glGetUniformLocation(prog, "row0"), lcol = p_glGetUniformLocation(prog, "col0");
    double tile = 2.0 * BM * 64 * Kp * 1e-9;  // GFLOP per work group
    int tiles = (int)(chunk_gflop / tile);
    if (tiles < 1) tiles = 1;
    int band = Np / 64;  // tiles per BM-row band
    if (tiles >= band) {
        int rows = tiles / band * BM;
        p_glUniform1i(lcol, 0);
        for (int r0 = 0; r0 < Mp; r0 += rows) {
            int nr = Mp - r0 < rows ? Mp - r0 : rows;
            p_glUniform1i(lrow, r0);
            p_glDispatchCompute(band, nr / BM, 1);
            p_glFlush();
        }
    } else {
        for (int r0 = 0; r0 < Mp; r0 += BM) {
            p_glUniform1i(lrow, r0);
            for (int c0 = 0; c0 < Np; c0 += tiles * 64) {
                int nc = Np - c0 < tiles * 64 ? Np - c0 : tiles * 64;
                p_glUniform1i(lcol, c0);
                p_glDispatchCompute(nc / 64, 1, 1);
                p_glFlush();
            }
        }
    }
    (void)unused;
}

static GLuint make_out(GLuint binding, size_t bytes)
{
    void *f = malloc(bytes);
    memset(f, 0xff, bytes);
    GLuint b = make_ssbo(binding, bytes, f);
    free(f);
    return b;
}

static GLuint upload(GLuint binding, const float *f, size_t n, int h16)
{
    void *d = (void *)f;
    if (h16) {
        uint16_t *h = malloc(n * 2);
        for (size_t i = 0; i < n; i++) h[i] = f2h(f[i]);
        d = h;
    }
    GLuint b = make_ssbo(binding, n * (h16 ? 2 : 4), d);
    if (h16) free(d);
    return b;
}

static void fp16_round(float *dst, const float *src, size_t n)
{
    for (size_t i = 0; i < n; i++) dst[i] = h2f(f2h(src[i]));
}

static double time_kernel(GLuint prog, int Mp, int Np, int Kp, int by_cols, double gflop, int *reps)
{
    dispatch(prog, Mp, Np, Kp, by_cols);  // warm-up
    p_glFinish();
    int n = 0;
    double t0 = now(), t;
    do {
        dispatch(prog, Mp, Np, Kp, by_cols);
        p_glFinish();
        n++;
        t = now() - t0;
    } while (t < 0.5 && gflop * n < 200);
    *reps = n;
    return t / n;
}

static void gemm(int M, int K, int N, int nv, char **vn)
{
    int Mp = rup(M, 64), Kp = rup(K, 32), Np = rup(N, 64);
    float *a = calloc((size_t)Mp * Kp, 4), *b = calloc((size_t)Kp * Np, 4), *c = calloc((size_t)Mp * Np, 4);
    float *ah = malloc((size_t)Mp * Kp * 4), *bh = malloc((size_t)Kp * Np * 4);
    for (int i = 0; i < M; i++)
        for (int k = 0; k < K; k++) a[(size_t)i * Kp + k] = frand();
    for (int k = 0; k < K; k++)
        for (int j = 0; j < N; j++) b[(size_t)k * Np + j] = frand();
    fp16_round(ah, a, (size_t)Mp * Kp);
    fp16_round(bh, b, (size_t)Kp * Np);
    double gflop = 2.0 * M * N * K * 1e-9;
    printf("gemm %d x %d x %d (%.3f GFLOP)\n", M, K, N, gflop);
    for (int v = 0; v < nv; v++) {
        const variant_t *var = find_variant(vn[v]);
        if (!var) { fprintf(stderr, "unknown variant %s\n", vn[v]); continue; }
        if (var->h16 && !has_ext(GL_EXT_SHADER_16BIT_STORAGE)) { printf("  %-5s no 16-bit storage\n", var->name); continue; }
        GLuint prog = build(var, "");
        if (!prog) continue;
        GLuint ba = upload(0, a, (size_t)Mp * Kp, var->h16), bb = upload(1, b, (size_t)Kp * Np, var->h16);
        GLuint bc = make_out(2, (size_t)Mp * Np * 4);
        int reps;
        double t = time_kernel(prog, Mp, Np, Kp, 0, gflop, &reps);
        read_ssbo(bc, (size_t)Mp * Np * 4, c);
        double e32 = 0, e16 = 0, ref = 0, cmax = 0;
        int nan = 0;
        int rows = M < 24 ? M : 24;
        for (int s = 0; s < rows; s++) {
            int i = (int)((long)s * (M - 1) / (rows > 1 ? rows - 1 : 1));
            for (int j = 0; j < N; j++) {
                double r32 = 0, r16 = 0;
                for (int k = 0; k < K; k++) {
                    r32 += (double)a[(size_t)i * Kp + k] * b[(size_t)k * Np + j];
                    r16 += (double)ah[(size_t)i * Kp + k] * bh[(size_t)k * Np + j];
                }
                double g = c[(size_t)i * Np + j];
                if (isnan(g)) nan++;
                e32 = fmax(e32, fabs(g - r32)), e16 = fmax(e16, fabs(g - r16));
                ref = fmax(ref, fabs(r32)), cmax = fmax(cmax, fabs(g));
            }
        }
        printf("  %-5s %7.2f GFLOP/s  %8.3f ms  x%-3d  max err vs fp32 %.3g, vs fp16 in %.3g  (max |ref| %.1f)%s\n",
               var->name, gflop / t, t * 1e3, reps, e32, e16, ref,
               nan ? "  INVALID (output not written)" : cmax == 0 ? "  INVALID (zero output)" : "");
        fflush(stdout);
        p_glDeleteBuffers(1, &ba), p_glDeleteBuffers(1, &bb), p_glDeleteBuffers(1, &bc);
        p_glDeleteProgram(prog);
    }
    free(a), free(b), free(c), free(ah), free(bh);
}

// conv1d, C in = C out = C, length L, kernel KW, stride 1, "same" padding:
// out[co][t] = sum_ci,kw w[co][ci][kw] * x[ci][t + kw - KW/2]. As a GEMM:
// M = C (out channels), K = C*KW, N = L, A = w as [C][C*KW], B[ci*KW+kw][t] =
// xpad[ci][t + kw] read directly from the padded input (no im2col buffer).
static void conv(int C, int L, int KW, int nv, char **vn)
{
    int Mp = rup(C, 64), K = C * KW, Kp = rup(K, 32), Np = rup(L, 64);
    if (Kp != K) die("conv: C*KW must be a multiple of 32");
    int LP = Np + KW - 1 + 3;  // padded row: KW/2 zeros left, the rest right
    float *w = calloc((size_t)Mp * Kp, 4), *x = calloc((size_t)C * LP, 4), *o = calloc((size_t)Mp * Np, 4);
    float *wh = malloc((size_t)Mp * Kp * 4), *xh = malloc((size_t)C * LP * 4);
    for (int co = 0; co < C; co++)
        for (int k = 0; k < K; k++) w[(size_t)co * Kp + k] = frand() * 0.05f;
    for (int ci = 0; ci < C; ci++)
        for (int t = 0; t < L; t++) x[(size_t)ci * LP + t + KW / 2] = frand();
    fp16_round(wh, w, (size_t)Mp * Kp);
    fp16_round(xh, x, (size_t)C * LP);
    double gflop = 2.0 * C * L * (double)K * 1e-9;
    printf("conv1d C=%d L=%d KW=%d (%.2f GFLOP)\n", C, L, KW, gflop);
    char extra[128];
    for (int v = 0; v < nv; v++) {
        const variant_t *var = find_variant(vn[v]);
        if (!var) { fprintf(stderr, "unknown variant %s\n", vn[v]); continue; }
        if (var->h16 && !has_ext(GL_EXT_SHADER_16BIT_STORAGE)) { printf("  %-5s no 16-bit storage\n", var->name); continue; }
        snprintf(extra, sizeof extra, "#define CONV 1\n#define KW %d\n#define SCALAR %s\n", KW, var->h16 ? "float16_t" : "float");
        GLuint prog = build(var, extra);
        if (!prog) continue;
        p_glUseProgram(prog);
        p_glUniform1i(p_glGetUniformLocation(prog, "LP"), LP);
        GLuint bw = upload(0, w, (size_t)Mp * Kp, var->h16), bx = upload(1, x, (size_t)C * LP, var->h16);
        GLuint bo = make_out(2, (size_t)Mp * Np * 4);
        int reps;
        double t = time_kernel(prog, Mp, Np, Kp, 1, gflop, &reps);
        read_ssbo(bo, (size_t)Mp * Np * 4, o);
        double e32 = 0, e16 = 0, ref = 0, omax = 0;
        int nan = 0;
        for (int s = 0; s < 16; s++) {
            int co = s * (C - 1) / 15;
            for (int tt = 0; tt < 256; tt++) {
                int t0 = (int)((long)tt * (L - 1) / 255);
                double r32 = 0, r16 = 0;
                for (int ci = 0; ci < C; ci++)
                    for (int kw = 0; kw < KW; kw++) {
                        size_t wi = (size_t)co * Kp + ci * KW + kw, xi = (size_t)ci * LP + t0 + kw;
                        r32 += (double)w[wi] * x[xi], r16 += (double)wh[wi] * xh[xi];
                    }
                double g = o[(size_t)co * Np + t0];
                if (isnan(g)) nan++;
                e32 = fmax(e32, fabs(g - r32)), e16 = fmax(e16, fabs(g - r16));
                ref = fmax(ref, fabs(r32)), omax = fmax(omax, fabs(g));
            }
        }
        printf("  %-5s %7.2f GFLOP/s  %8.1f ms  x%-3d  max err vs fp32 %.3g, vs fp16 in %.3g  (max |ref| %.2f)%s\n",
               var->name, gflop / t, t * 1e3, reps, e32, e16, ref,
               nan ? "  INVALID (output not written)" : omax == 0 ? "  INVALID (zero output)" : "");
        fflush(stdout);
        p_glDeleteBuffers(1, &bw), p_glDeleteBuffers(1, &bx), p_glDeleteBuffers(1, &bo);
        p_glDeleteProgram(prog);
    }
    free(w), free(x), free(o), free(wh), free(xh);
}

int main(int argc, char **argv)
{
    if (argc < 2) die("usage: gles16 info | test | gemm M K N [variant...] | conv C L KW [variant...]");
    if (getenv("GLES16_CHUNK_GFLOP")) chunk_gflop = atof(getenv("GLES16_CHUNK_GFLOP"));
    if (getenv("GLES16_RM")) RM = atoi(getenv("GLES16_RM"));
    if (getenv("GLES16_LY")) LY = atoi(getenv("GLES16_LY"));
    BM = RM * LY;
    if (64 % BM) die("RM * LY must divide 64");
    gl_init();
    static char *all[] = {"f32", "m32", "h32", "h16", "hmix"};
    if (!strcmp(argv[1], "info")) info();
    else if (!strcmp(argv[1], "test")) {
        info();
        tests();
        return fails != 0;
    } else if (!strcmp(argv[1], "gemm") && argc >= 5) {
        int nv = argc - 5;
        gemm(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), nv ? nv : 5, nv ? argv + 5 : all);
    } else if (!strcmp(argv[1], "conv") && argc >= 5) {
        int nv = argc - 5;
        conv(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), nv ? nv : 5, nv ? argv + 5 : all);
    } else die("bad arguments");
    return 0;
}
