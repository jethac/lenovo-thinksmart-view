// cpu-gemm: the CPU baseline for gles-sgemm, using ggml's CPU backend (the
// same ggml the transcribe.cpp build ships, so the same kernels the encoder
// uses: llamafile tinyBLAS for F32 x F32 on NEON, ggml's own vec_dot for Q8_0).
//
//   cpu-gemm THREADS TYPE M K N      TYPE = f32 | q8_0 | f16
//
// C (MxN) = A (MxK, activations, F32) times B (KxN, weights, TYPE). In ggml
// terms: ggml_mul_mat(w[K,N], x[K,M]) -> [N,M]. Weights are quantised once
// outside the timing; quantising the activations to the weights' vec_dot type
// (for Q8_0) is inside it, as in the real encoder.
#include "ggml.h"
#include "ggml-cpu.h"
#include <math.h>
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

int main(int argc, char **argv)
{
    if (argc != 6) {
        fprintf(stderr, "usage: %s THREADS f32|q8_0|f16 M K N\n", argv[0]);
        return 2;
    }
    int nt = atoi(argv[1]), M = atoi(argv[3]), K = atoi(argv[4]), N = atoi(argv[5]);
    enum ggml_type wt = !strcmp(argv[2], "q8_0") ? GGML_TYPE_Q8_0 : !strcmp(argv[2], "f16") ? GGML_TYPE_F16 : GGML_TYPE_F32;
    size_t mem = ggml_row_size(wt, K) * N + (size_t)K * N * 4 + (size_t)K * M * 4 + (size_t)N * M * 4 + (64u << 20);
    struct ggml_init_params ip = {mem, NULL, false};
    struct ggml_context *ctx = ggml_init(ip);
    struct ggml_tensor *w = ggml_new_tensor_2d(ctx, wt, K, N);
    struct ggml_tensor *x = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, M);
    float *wf = malloc((size_t)K * N * 4);
    unsigned s = 1;
    for (size_t i = 0; i < (size_t)K * N; i++) { s = s * 1664525u + 1013904223u; wf[i] = ((s >> 8) & 0xffff) / 32768.0f - 1; }
    for (size_t i = 0; i < (size_t)K * M; i++) { s = s * 1664525u + 1013904223u; ((float *)x->data)[i] = ((s >> 8) & 0xffff) / 32768.0f - 1; }
    if (wt == GGML_TYPE_F32) memcpy(w->data, wf, (size_t)K * N * 4);
    else ggml_quantize_chunk(wt, wf, w->data, 0, N, K, NULL);
    struct ggml_tensor *y = ggml_mul_mat(ctx, w, x);
    struct ggml_cgraph *gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, y);

    struct ggml_threadpool_params tpp = ggml_threadpool_params_default(nt);
    struct ggml_threadpool *tp = ggml_threadpool_new(&tpp);
    struct ggml_cplan plan = ggml_graph_plan(gf, nt, tp);
    plan.work_data = malloc(plan.work_size + 1);
    ggml_graph_compute(gf, &plan);  // warm-up
    int reps = 0;
    double t0 = now(), t;
    do {
        ggml_graph_compute(gf, &plan);
        reps++;
        t = now() - t0;
    } while (t < 1.0 && reps < 200);
    double tk = t / reps;

    // Check sampled rows against a double reference on the (dequantised) weights.
    float *wd = malloc((size_t)K * N * 4);
    if (wt == GGML_TYPE_F32) memcpy(wd, w->data, (size_t)K * N * 4);
    else {
        const struct ggml_type_traits *tr = ggml_get_type_traits(wt);
        for (int j = 0; j < N; j++)
            tr->to_float((const char *)w->data + j * w->nb[1], wd + (size_t)j * K, K);
    }
    double err = 0;
    for (int si = 0; si < 8; si++) {
        int i = (int)((long)si * (M - 1) / 7);
        for (int j = 0; j < N; j++) {
            double acc = 0;
            for (int k = 0; k < K; k++) acc += (double)((float *)x->data)[(size_t)i * K + k] * wd[(size_t)j * K + k];
            double e = fabs(acc - ((float *)y->data)[(size_t)i * N + j]);
            if (e > err) err = e;
        }
    }
    printf("cpu-ggml   M=%-5d K=%-5d N=%-5d %-4s threads %d  %8.3f ms %6.2f GFLOP/s  maxerr %.2e reps %d\n", M, K, N,
           argv[2], nt, tk * 1e3, 2.0 * M * N * K / tk * 1e-9, err, reps);
    ggml_threadpool_free(tp);
    ggml_free(ctx);
    return 0;
}
