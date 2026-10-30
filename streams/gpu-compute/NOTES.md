# gpu-compute: Adreno 506 GLES compute vs the CPU, for the Qwen3-ASR encoder

Question: can the Adreno 506 (Mesa freedreno, OpenGL ES compute shaders) usefully speed up the Qwen3-ASR-0.6B audio encoder compared with the 8x Cortex-A53, so that custom GLSL kernels are worth writing?

**Answer: no, not now.** The best FP32 GEMM kernel I could write runs at **14.4 GFLOP/s** and stays there (no throttling). That is the same as ggml's CPU F32 GEMM on 8 threads for K ≤ 1024, and **half of ggml's CPU Q8_0 GEMM (25–28 GFLOP/s)**, which is what the encoder's linear layers already use. The GPU wins only against ggml's F32 path when K is large (conv stem, K = 4320: GPU 13.3 vs CPU 4.4 GFLOP/s). Converting the conv weights to Q8_0 on the CPU (27 GFLOP/s) is a cheaper fix that beats the GPU too. See [Recommendation](#recommendation).

Measured 2026-10-30, Linux 7.3 baseline kernel, Mesa 26.2.6 (ALARM `mesa 1:26.2.6-1`), CPU at 1804.8 MHz (schedutil), GPU devfreq `simple_ondemand` (it goes to 650 MHz under load).

## What the GPU exposes

Surfaceless EGL on the render node (`EGL_PLATFORM_SURFACELESS_MESA`, `EGL_KHR_no_config_context`). No DRM master needed; the idle-screen daemon was unaffected throughout.

| | |
| --- | --- |
| EGL | 1.5, Mesa Project; client APIs OpenGL, OpenGL_ES |
| Highest GLES context | **OpenGL ES 3.1** (a 3.2 request fails with `EGL_BAD_MATCH`) |
| GL_RENDERER / GL_VERSION | `FD506` / `OpenGL ES 3.1 Mesa 26.2.6-arch1.1` |
| GL_SHADING_LANGUAGE_VERSION | `OpenGL ES GLSL ES 3.10` |
| Desktop GL | 3.1 core and compat, GLSL 1.40 |
| MAX_COMPUTE_WORK_GROUP_COUNT | 65535, 65535, 65535 |
| MAX_COMPUTE_WORK_GROUP_SIZE | 1024, 1024, 64 |
| MAX_COMPUTE_WORK_GROUP_INVOCATIONS | 512 (in practice ≤ 128 for register-heavy kernels; see faults below) |
| MAX_COMPUTE_SHARED_MEMORY_SIZE | 32768 |
| MAX_SHADER_STORAGE_BLOCK_SIZE | 134217728 (128 MiB) |
| MAX_SHADER_STORAGE_BUFFER_BINDINGS | 36 (12 per compute shader) |
| MAX_TEXTURE_BUFFER_SIZE | 134217728 |
| MAX_TEXTURE_SIZE | 16384 |
| Precision (fragment stage; GLES cannot query compute) | highp float 2^±127, 23 bits; mediump/lowp float 2^±15, 10 bits (real FP16) |

Extensions that matter for compute: `GL_EXT_buffer_storage`, `GL_EXT_texture_buffer`/`GL_OES_texture_buffer`, `GL_OES_shader_image_atomic`, `GL_EXT_disjoint_timer_query`, `GL_EXT_shader_integer_mix`, `GL_MESA_shader_integer_functions`, `GL_OES_texture_half_float`, `GL_EXT_color_buffer_half_float`. **Not** exposed: `GL_EXT_shader_16bit_storage`, `GL_EXT_shader_explicit_arithmetic_types_float16`, `GL_AMD_gpu_shader_half_float`, `GL_KHR_shader_subgroup`, `GL_EXT_shader_framebuffer_fetch`. So FP16 arithmetic is reachable only through `mediump`; there is no 16-bit SSBO storage.

Full outputs: `results/gles-info.txt`, `results/eglinfo-surfaceless.txt`, `results/es2_info.txt`. `es2_info` (mesa-utils 9.0.0) only opens an X display, so it has nothing to report here; `gles-sgemm info` covers it.

**No Vulkan** (no Turnip for a5xx; see `devices/gpu/ANALYSIS.md`).

### OpenCL (Rusticl)

`opencl-mesa 1:26.2.6-1` exists for aarch64 in ALARM. I installed it with `ocl-icd` and `clinfo` (same tmpfs method, `/tmp/ocl-root`) and then removed it again.

- `RUSTICL_ENABLE=freedreno clinfo`: platform `rusticl` (OpenCL 3.1), **0 devices**.
- Control: in a private mount namespace with libclc at its built-in path (`unshare -m`, bind mount, nothing on root changed), `RUSTICL_ENABLE=llvmpipe` lists `llvmpipe (LLVM 23.1.4, 128 bits)`, but `RUSTICL_ENABLE=freedreno` and `freedreno,llvmpipe` still list no FD506 device. So Rusticl works, and it does not support freedreno a5xx. Output: `results/clinfo.txt`.

## Benchmark

- `src/gles-sgemm.c`: GLES 3.1 compute, `C = A·B`, row-major FP32 in SSBOs. The host zero-pads to tile multiples; GFLOP/s always counts the unpadded `2·M·N·K`. Timing is wall clock around `glFinish`, repeated for ≥ 0.5 s. Copies are timed separately: upload A, upload B (`glBufferSubData`), download C (`glMapBufferRange` read + memcpy). Correctness: 24 sampled rows checked against a double-precision reference. Any result whose output stays zero is reported as INVALID. (Before I added that check, one kernel "passed" by reading a stale buffer.)
- `src/cpu-gemm.c`: CPU baseline using **ggml's CPU backend** from the asr stream's transcribe.cpp aarch64 build (`streams/asr/work/build-a53/ggml/src/*.a`, `GGML_LLAMAFILE=ON`, no OpenMP). That is the same code the encoder runs: tinyBLAS (llamafile sgemm) for F32 x F32 on NEON, and ggml's Q8_0 vec_dot for Q8_0 weights. The activation quantisation for Q8_0 is inside the timing. It runs one `ggml_mul_mat` on a persistent threadpool.
- `scripts/build.sh` builds both (host clang + lld, sysroot `streams/asr/work/sysroot`; gles-sgemm is linked dynamically and `dlopen`s `libEGL.so.1`). `scripts/install-mesa-tmpfs.sh`, `scripts/device-sweep.sh` and `scripts/device-soak.sh` run on the device under the lock.

Kernels (all names in the source):

| Kernel | Scheme |
| --- | --- |
| `naive16` | one output per invocation, 16x16 |
| `tile16` | classic 16x16 shared-memory tiles, one output per invocation |
| `r4x4_8x8`, `r8x4_8x8` | register blocking without shared memory: 4 (or 8) rows x vec4 per invocation, vec4 loads |
| `st64x32` | shared-memory tiles 64x32, BK = 16, 4x4 per invocation, 128 invocations |
| **`st64r8k32`** | shared-memory tiles 64x64, BK = 32, **8 rows x vec4 per invocation, 128 invocations**: the best kernel |
| `st64r8k32t8` / `t16` | the same, but B (the weights) comes from an RGBA8_SNORM (int8 with a per-column scale) or RGBA16F texture through `texelFetch` |
| `r4x4_8x8h` etc. | `precision mediump float` variants (FP16 arithmetic) |

### Results (GFLOP/s)

GPU = `st64r8k32`. "+copies" = upload A and B, kernel, download C. "B resident" = weights already on the GPU (upload A, kernel, download C), which is the realistic encoder case. CPU = ggml, 8 threads (4 threads gives almost exactly half). Log: `results/sweep-20261030-2211.log`.

| Shape (M x K x N) | What | GPU kernel | GPU +copies | GPU B resident | GPU int8-texture B (kernel) | CPU F32 | CPU Q8_0 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 512³ | square | 13.7 | 9.0 | 9.3 | 13.7 | 18.6 | 25.5 |
| 1024³ | square | 14.3 | 11.3 | 11.5 | 14.4 | 14.3 | 28.3 |
| 2048³ | square | 13.7 | 12.5 | 12.6 | 14.5 | 4.2 | 28.3 |
| 64 x 896 x 896 | attn q/k/v/out, 5 s audio | 12.8 | 8.8 | 10.6 | 12.8 | 19.0 | 27.7 |
| 128 x 896 x 896 | attn proj, 10 s | 13.4 | 9.4 | 10.3 | 13.5 | 18.1 | 27.6 |
| 384 x 896 x 896 | attn proj, 30 s | 14.0 | 10.4 | 10.7 | 14.2 | 18.3 | 27.9 |
| 128 x 896 x 3584 | FFN fc1, 10 s | 13.4 | 9.3 | 10.6 | 14.2 | 19.2 | 28.7 |
| 128 x 3584 x 896 | FFN fc2, 10 s | 14.0 | 11.6 | 12.8 | 14.4 | 4.8 | 27.8 |
| 384 x 896 x 3584 | FFN fc1, 30 s | 13.5 | 10.6 | 10.9 | 14.4 | 19.3 | 28.7 |
| 64 x 7680 x 896 | conv_out, 5 s | 14.1 | 10.6 | 13.4 | 14.6 | 3.8 | 24.5 |
| 4000 x 4320 x 480 | conv1 im2col, 5 s | 13.2 | 12.2 | 12.3 | 13.4 | 4.4 | 27.1 |
| 1040 x 4320 x 480 | conv2 im2col, 5 s | 12.7 | 11.6 | 11.8 | 12.9 | 4.4 | 27.0 |

The other kernels at 1024³: naive16 invalid (hangcheck), tile16 1.15, r4x4 3.0, r8x4 4.1, st64x32 8.9. The order is the same on every shape.

Max abs error, FP32 GPU vs double: 2e-5 to 5e-4 (grows with K), the same as the CPU's.

What the table shows:

- **The GPU FP32 ceiling is about 14 GFLOP/s**, roughly 11% of the Adreno 506's commonly quoted ~125 GFLOP/s FP32 peak (96 ALUs x 2 x 650 MHz). It does not depend on shape, so the kernel is limited by issue and latency, not by DRAM.
- **ggml's CPU F32 GEMM falls from about 19 to about 4.4 GFLOP/s once K ≥ about 2048** (fc2, conv_out, conv1/conv2, 2048³). That is where the GPU beats it, by about 3x. **ggml Q8_0 stays at 25–28 GFLOP/s on every shape** and beats the GPU by about 2x everywhere.
- **Readback is slow.** Mapping a GPU buffer for reading gives only 120–150 MB/s (for example 34 ms for 4 MiB, 106 ms for 16 MiB). Uploads run at 1.3–1.7 GB/s. A GPU encoder would have to keep every intermediate on the GPU and read back only the final `T x 1024` output.

### FP16 (`mediump`)

ir3 really does lower `mediump` to FP16 on a5xx. With `IR3_SHADER_DEBUG=disasm` and `MESA_SHADER_CACHE_DISABLE=true`, `r4x4_8x8h` compiles to `mad.f16` on half registers (`12 half, 8 full` registers, `double_threadsize`), against `mad.f32` and 16 full registers for highp. It is **slower**, not faster: 2.2 against 3.0 GFLOP/s at 1024³ (about 0.75x on every shape). The SSBO data is 32-bit, so every load needs a `cov.f32f16`, and the half-precision accumulator breaks accuracy: max error 0.17 at K = 512, 0.48 at K = 1024, 1.4 at K = 3584, 4.0 at K = 7680 (|C| ≈ 20–45). There is no 16-bit storage extension that would remove the conversions. Mixed precision (FP16 multiply, FP32 accumulate) would at best get the speed back. FP16 is not a lever here.

### Weights from a texture (int8 / fp16 stand-in)

With B read through `texelFetch` from an RGBA8_SNORM texture (symmetric int8 per column, scale applied at the end) or RGBA16F, the kernel speed is **the same as FP32 SSBO B, within 1–6%** (int8: 14.4 vs 14.3 GFLOP/s at 1024³; 14.6 vs 14.1 on conv_out). The arithmetic is exact against the dequantised weights (error ≤ 2e-4, as FP32). The error against the FP32 weights is the quantisation error: int8 0.1–0.6, fp16 0.005–0.02. Because the kernel is not bandwidth-bound, lower weight traffic buys no speed. What it does buy is 4x less GPU memory for weights, which would matter for residency on a 2 GB device. The effective weight read rate is tiny (K·N bytes once per GEMM, 0.01–0.2 GB/s).

## Faults and the hangcheck (important for any real kernel)

Two separate ways the GPU refuses work. Both are recovered by the kernel, the display keeps running, and the result is silently zero:

1. **CP fault on some work-group shapes.** `a5xx_irq: gpu fault ring 0 ... status E40801C3` followed by `hangcheck recover`, on every dispatch of: 16x16-invocation shared-memory kernels (`st64`), and several heavier 128-invocation shared-memory variants (`st64r8`, `st128r8`, `st64x32k32`, `st128r8k32`, `st64r8h`, `st64r8k32h`). `st64r8`, for example, uses 24 full registers in its ir3 build. `st64` and `st64x32` have identical ISA statistics and differ only in work-group size (256 vs 128). `st64r8k32` (16 full registers) runs, while `st64r8` (BK = 16, 24 full registers) faults. Mesa reports `MAX_COMPUTE_WORK_GROUP_INVOCATIONS` = 512 and gives no error, so register footprint x invocations goes beyond what a5xx can actually run. Treat the limit as ≤ 128 invocations and ≤ 16 full registers, and check every kernel's output.
2. **Hangcheck on long submissions** (`results/flush-rerun.log`). The msm hangcheck period is 500 ms (`/sys/kernel/debug/dri/0/hangcheck_period_ms`). Any job running longer than about 0.5–2 s is declared a lockup and killed (`hangcheck detected gpu lockup rb 0`), for example the slow naive and r4x4 kernels on large shapes. gles-sgemm splits every GEMM into row chunks of ≤ 0.25 GFLOP with a `glFlush` per chunk (about 20 ms each for the fast kernel), so the useful kernels never trip it.

## Sustained run, thermals, power

`scripts/device-soak.sh`, `results/soak-20261030-2234.log`: `st64r8k32` on 1024³ for 60 s.

- GPU at **650 MHz for all 60 s**, **14.30–14.37 GFLOP/s** in every 5 s window: no throttling.
- Temperatures (°C): `gpu-thermal` 33 → 35. All `cpu*-thermal` stayed at 34–35, `pm8953` 34. The 20 s cool-down brought gpu-thermal back to 31. By comparison, the CPU-and-GPU run below took the CPU zones to 40–43 °C.
- Host CPU used by the GPU process: 0.43 s user + 0.21 s sys in 60 s, about 1% of one core (blocked in `glFinish`).
- Power: no current or power sensor is readable on this board (no battery; PMIC fuel gauge unused). The heat rise suggests the GPU at this load draws well under a watt over idle, but I did not measure it.

## CPU and GPU at the same time

Same log, GPU soak running while the CPU runs ggml:

| CPU workload | alone | with GPU busy |
| --- | ---: | ---: |
| F32 1024³, 4 threads | 7.99 | 7.87 GFLOP/s |
| F32 1024³, 8 threads | 14.12 | 14.03 GFLOP/s |
| Q8_0 GEMV 1 x 1024 x 3072 (decoder-like, bandwidth-bound), 4 threads | 0.666 ms | 0.783 ms (+18%) |
| same, 8 threads | 0.608 ms | 0.732 ms (+20%) |

Meanwhile the GPU held 14.05–14.37 GFLOP/s, with one dip to 14.05 while the CPU ran 8 threads. So they do run concurrently. Compute-bound CPU work is unaffected, but **token-by-token decoding, which is bound by memory bandwidth, slows by about 18–20%** while the GPU runs a GEMM, because both share the single LPDDR3 channel.

## Recommendation

Encoder cost per second of audio (12.5 tokens/s after the 8x conv downsampling, d_model 896, FFN 3584, 18 layers, 480-channel conv stem, F32 conv weights, Q8_0 linear weights, from the Q8_0 GGUF):

| Part | GFLOP per s of audio | CPU today | GPU (st64r8k32) | CPU, conv weights in Q8_0 |
| --- | ---: | ---: | ---: | ---: |
| Conv stem (conv1 + conv2 im2col GEMM, conv_out) | about 4.4 | F32: about 1.0 s | about 0.33 s | about 0.16 s |
| Transformer linears (q, k, v, out, fc1, fc2 x 18) | about 4.3 | Q8_0: about 0.16 s | about 0.31 s (+ copies) | about 0.16 s |

(These are estimates from the GEMM rates above. The conv rows assume ggml's F32 path really runs at the measured 4.4 GFLOP/s for these shapes. The asr stream should confirm with an encoder profile.)

1. **Do not build a GLES compute path for the encoder now.** For the attention projections and the FFN, the GPU is half the speed of the Q8_0 CPU path the encoder already uses, before counting copies and the slow readback. Even as pure offload (the CPU decoding while the GPU encodes), it would slow the decoder by about 20% through memory contention, for an encoder share the CPU already runs in about 0.3 s per second of audio.
2. **The one place the GPU wins is the F32 conv stem** (13 vs 4.4 GFLOP/s), and only because ggml's F32 GEMM is weak for large K on the A53. The cheaper fix is on the CPU: store `enc.conv.1/2.weight` (and keep `conv_out`) as Q8_0, or F16 run through the Q8_0 path. That gives about 27 GFLOP/s, 2x the GPU, and costs only a WER check. This is for the asr stream; it probably takes the conv stem from about 1 s to about 0.16 s per second of audio, the largest single encoder win available.
3. **Revisit the GPU only if** a profile shows the encoder is still a large share of end-to-end latency after that, and the CPU is saturated by decoding. Even then, the only part worth porting is the conv stem plus the FFN, chained entirely on the GPU (im2col, GEMM, GELU, next GEMM) with weights resident (int8 textures: 4x less memory, same speed) and a single readback of the encoder output. Expect at most about 14 GFLOP/s, ≤ 128 invocations per work group, and dispatches under about 100 ms, and verify every kernel's output.

## Left on the device

Nothing on the root filesystem. The root partition has about 48–72 MiB free, and Mesa with its dependencies is 250 MiB installed (llvm-libs alone 164 MiB), so a normal `pacman -U` into `/` is impossible until stage-b grows root. Instead:

- **`/tmp/gpu-root`** (tmpfs, **253 MiB of RAM**, gone at the next reboot): installed with `pacman -U --root /tmp/gpu-root --dbpath /tmp/gpu-root/var/lib/pacman -dd --hookdir <empty>`. Signatures were checked against the device keyring (SigLevel Required; also spot-checked with `pacman-key --verify`: good signature from `68B3537F39A313B3E574D06777193F152BDBE6A6`, Arch Linux ARM Build System). It contains the 13 packages below, `env.sh` (source it to use this Mesa), and the test binaries `gles-sgemm` and `cpu-gemm`. Remove it with `rm -rf /tmp/gpu-root`, which frees the RAM. If other streams need the memory for model benchmarks, remove it first.

  | Package | Installed size |
  | --- | ---: |
  | mesa 1:26.2.6-1 | 63.5 MiB |
  | llvm-libs 23.1.4-1.1 | 163.7 MiB |
  | spirv-tools 1:1.4.363.0-1 | 10.8 MiB |
  | libglvnd 1.7.0-3 | 5.4 MiB |
  | mesa-utils 9.0.0-7 | 1.9 MiB |
  | wayland 1.26.0-1 | 1.1 MiB |
  | vulkan-icd-loader 1.4.363.0-1 | 0.8 MiB |
  | lm_sensors 1:3.6.2-1 | 0.5 MiB |
  | libxkbcommon-x11 1.13.2-1 | 0.2 MiB |
  | libdecor 0.2.5-1 | 0.2 MiB |
  | libxxf86vm 1.1.7-1 | 0.1 MiB |
  | libxshmfence 1.3.3-1 | 0.1 MiB |
  | default-cursors 3-1 | 0 |

  Other dependencies (libdrm, libx11, libxcb, expat, zstd, libelf, ...) were already on the device and are used from `/usr/lib`. To reinstall after a reboot, run `scripts/install-mesa-tmpfs.sh mesa` from the laptop (about 30 s, offline).
- **Removed again:** opencl-mesa 1:26.2.6-1 (41.9 MiB), clang-libs 23.1.4-1.1 (133.1 MiB), libclc 23.1.4-1.1 (54.1 MiB), spirv-llvm-translator 23.1.2-1 (5.3 MiB), ocl-icd 2.3.5-1 (0.6 MiB), clinfo 3.0.25.02.14-1 (0.2 MiB), all from `/tmp/ocl-root`.
- **Clock:** set twice from the laptop (`date -s @<laptop epoch>`) before pacman's signature checks. The device has no NTP, so it drifts back after a reboot (it had read 19 October).
- The tablet was rebooted twice during this work by other streams (boot_id changed). That wiped `/tmp/gpu-root` once, and I reinstalled it. I did not reboot it.
- GPU recoveries were logged in dmesg during kernel exploration (the faults above). No lasting effect: after them `tsv-idle-screen` was `active` and later runs had no faults.

## Downloads

`downloads/alarm/` (git-ignored): the 19 package files and their `.sig` files from `http://mirror.archlinuxarm.org/aarch64/extra/` (98 MiB), listed in `downloads/alarm/urls.txt`. Sizes match the device's sync DB. Signatures were verified by pacman on the device.

## Reproduce

```sh
streams/gpu-compute/scripts/build.sh                  # build/gles-sgemm, build/cpu-gemm
streams/gpu-compute/scripts/install-mesa-tmpfs.sh mesa
streams/gpu-compute/scripts/device-sweep.sh           # results/sweep-*.log (about 25 min)
streams/gpu-compute/scripts/device-soak.sh            # results/soak-*.log (about 3 min)
# on the device:  . /tmp/gpu-root/env.sh; /tmp/gpu-root/gles-sgemm info
```
