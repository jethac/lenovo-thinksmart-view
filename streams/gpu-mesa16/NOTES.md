# gpu-mesa16: GL_EXT_shader_16bit_storage for the Adreno 506 (Mesa freedreno, a5xx)

Goal: FP16 loads and stores from SSBOs (and 16-bit UBO reads) in GLES 3.1 compute shaders on the ThinkSmart View's Adreno 506, without a `cov.f32f16` per load, for a GPU TTS vocoder (convolution-heavy; about 48 GFLOP per second of audio on the CPU).

**Answer.**

- **The hardware does it.** a5xx `ldgb`/`stgb` with a `u16`/`f16` type load and store 16-bit values to and from half registers, 1 to 4 components, at 2-byte granularity. This was checked on the device with hand-assembled ir3 (below).
- **The patch series** (7 patches on Mesa 26.2.6) adds `GL_EXT_shader_16bit_storage` to Mesa's GLSL front end, makes ir3 emit 16-bit `ldgb`/`stgb` on a5xx, and exposes the extension on freedreno a5xx. It passes its own tests (15/15) and dEQP-GLES31 SSBO/compute/interface-query with no change from stock. The inner loop of an FP16 GEMM becomes `ldgb.u16 → stl.u16 → ldl.u16 → mad.f16`, with no conversions.
- **The register-file finding** (patch 7; this answers the kokoro-gpu question). On a5xx, ir3 ignores the cost of half registers and has no workgroup-fit limit. Large compute workgroups with a barrier therefore hang the GPU, and big fragment shaders silently write zeros. The hardware budget is `threads × (full + half/2) ≤ 2048 vec4`, which is tiny. Patch 7 makes those shaders spill instead of failing. It fixes 3 dEQP compute hangs and the kokoro-gpu zero-output kernels, but it is **not a performance unlock**: the fixed kernels are correct but no faster than the small ones that already worked.
- **Speed: FP16 is not a lever on this GPU.**

  | | GFLOP/s | vs 14.4 FP32 baseline |
  | --- | ---: | ---: |
  | Best FP32 GEMM (unchanged) | 13.3–14.4 | 1x |
  | FP16 storage + FP16 math (`h16`) | 12.8–13.6 | 0.9–0.95x |
  | FP16 storage + FP32 accumulation, best tile (`h32`) | 10.3–11.2 | 0.75x |
  | FP16 storage + FP32 math, same tile as FP32 | equal to FP32 | 1x |
  | Vocoder-shaped conv1d (512 ch, k 7, L 24000, 88 GFLOP), FP32 | 12.6 | |
  | Same conv1d, FP16 storage + math | 12.3 | |
  | Same conv1d, FP16 storage + FP32 math | 9.9 | |

  The 0.9–0.95x for `h16` is up from the gpu-compute stream's 0.75x for mediump, and that mediump GEMM kernel shape hangs on stock Mesa. FP16 storage halves memory and bandwidth for free, but the kernels are limited by issue and latency, not memory. At about 12.5 GFLOP/s, 48 GFLOP per second of audio is about **3.8x slower than real time** on the GPU.

Mesa base: **mesa-26.2.6, commit `8e87a503ebd91408c88596d1b9eeb5f4c0b2088d`** (the version ALARM ships, `mesa 1:26.2.6-1`, the one gpu-compute used). Measured 2026-11-01 on the Linux 7.3 baseline kernel, GPU devfreq `simple_ondemand` (19.2 MHz idle → 650 MHz under load).

## 1. Hardware: what a5xx cat6 does with 16-bit SSBO access

### ISA evidence (Mesa source)

- **ir3 emits for a5xx SSBOs:** `ldgb`/`stgb` (`src/freedreno/ir3/ir3_a4xx.c`, `#define GPU 500`), always `untyped.4d.u32`.
  - Sources: the IBO slot, a 64-bit byte offset `(byte, 0)`, and a separate "dword offset".
  - The data type was hard-coded `TYPE_U32`, so a 16-bit `load_ssbo` read 32 bits.
- **`isa/ir3-cat6.xml`:** `#instruction-cat6-a3xx-ibo` (ldgb/ldib/stgb/stib, gen ≤ 599) encodes:
  - `TYPE` (3 bits, in the common cat6 base, so u16/f16/u32/f32);
  - `TYPE_SIZE_MINUS_ONE` (1–4 components);
  - `TYPED`;
  - `D_MINUS_ONE`.
  
  The destination is a plain `#reg-gpr`, with no half bit. On a5xx (separate half and full files) the half-ness comes from the type, as for `ldl`/`stl`. Nothing in the encoding rules out 16-bit types.
- **`registers/adreno/a5xx.xml`:** the SSBO state (`A5XX_SSBO_1`, which fd5 emits with `WIDTH` = size in bytes and no `FMT` for buffers) has no element format. The access size therefore comes from the instruction, unlike a6xx.
- **a6xx/turnip (`ir3_a6xx.c`, `tu_device.cc`):** `ldib`/`stib` `.u16`, plus a *second, 16-bit SSBO descriptor* (`storage_16bit` device prop, R16 format) because a6xx addresses SSBOs in element units of the descriptor's format.
  - That is why gallium a6xx does not get this for free.
  - a6xx has merged half/full registers; a5xx does not (`ir3_compiler.c`: `mergedregs` from a6xx).

### On the device (stock Mesa, hand-written ir3)

Computerator has no a5xx backend (`computerator/main.cc`: a4xx and a6xx+ only). I used Mesa's `IR3_SHADER_OVERRIDE_PATH` instead.

**Method.** `probes/u32.comp` is a 32-bit SSBO copy. Its ir3 binary, keyed by blake3, is replaced with each `probes/asm/P*.asm`. Input: u16 element `i = 0xA000 + i`; output pre-filled with `0xEE`. Script: `scripts/device-isa-probe.sh`; logs `results/isa-probe-*.log`.

| Probe | Instruction | Result |
| --- | --- | --- |
| P1 | `ldgb.untyped.4d.u16.1 hr2.x, g[1], (2i,0), i` | `a000+i` zero-extended: **16-bit load works** |
| P2 | same, element offset 0 | correct: **the address is the byte offset** |
| P3 | byte offset 0, element offset i | always element 0: the element offset is **ignored** |
| P4 | byte offset 4i | elements 0, 2, 4, ...: byte addressing |
| P5 | `ldgb...u16.4`, byte 8i | 4 consecutive halves: **vec4 of 16-bit works** |
| P6 | `stgb...u16.1` at byte 4i+2 (odd halves) | only odd halves written, even ones untouched: **2-byte-granular stores, no clobbering** |
| P7 | `ldgb.f16` → `add.f hr` → `stgb.f16` | `a000+i` doubled = `a400+i`: f16 load, half ALU, f16 store |
| P8 | `ldgb/stgb ...u16.2` | correct copy |
| P9, PA | 16-bit store with only byte or only element offset | byte offset used, element offset ignored |
| PB | the same for u32 | byte offset used for 32-bit too |

So a5xx can do it directly. No image or texture detour is needed.

## 2. The patches (`patches/`, `git am` onto `8e87a50`)

1. **`ir3: support 16-bit SSBO loads and stores on a5xx`.**
   - Picks the `ldgb`/`stgb` type from the bit size (u16 for 16-bit; the destination is already made half by `ir3_put_def`).
   - Validates `stgb` sources like `stib`.
   - No offset change is needed, since the hardware uses the byte offset. 16-bit is asserted to gen 5 only (a4xx is untested).
2. **`mesa: add EXT_shader_16bit_storage to the extension table`.** GLSL 1.40+/ESSL 3.10+ per the spec.
3. **`glsl: implement EXT_shader_16bit_storage`.**
   - Types: `float16_t`/`f16vec2-4` (reusing the AMD_gpu_shader_half_float keywords), plus new `int16_t`/`i16vec2-4`/`uint16_t`/`u16vec2-4`.
   - Constructor conversions: int16 ↔ int/uint (new), float16 ↔ float (existing). Every other 16-bit conversion is rejected.
   - Rejected outside uniform/buffer blocks: local, global and shared declarations, arithmetic, and comparisons (unless AMD_gpu_shader_half_float is enabled).
   - std140/std430 layout and the NIR lowering to 16-bit `load_ssbo`/`store_ssbo`/`load_ubo` already handled 16-bit types.
   - Not enforced: the bans on swizzles and vector array subscripting of 16-bit vectors. Default-block uniform structs with 16-bit members are rejected, although the spec allows them.
4. **`gallium: add pipe_caps::shader_16bit_storage`** (with `docs/gallium/screen.rst`).
5. **`st/mesa: enable EXT_shader_16bit_storage from pipe_caps::shader_16bit_storage`.**
6. **`freedreno: expose EXT_shader_16bit_storage on a5xx`** (with `docs/features.txt`).
   - Only on a5xx. a6xx needs the 16-bit descriptor turnip uses.
   - 16-bit UBO loads (including UBOs pushed to the const file) are lowered by ir3 to 32-bit loads plus extraction. That costs one shift/convert per load and needed no change. GLES has no push constants.
7. **`ir3: count half registers in the a5xx register footprint`.** See [Register footprint](#3-register-footprint-on-a5xx-patch-7).

The shared memory question answered itself. With 16-bit storage, mediump `shared` arrays are already lowered to 16-bit `stl.u16`/`ldl.u16` by NIR's mediump lowering. The extension itself does not allow 16-bit types in `shared`.

ir3 output for the FP16 GEMM (`h16`, `IR3_SHADER_DEBUG=disasm`):

```
ldgb.untyped.4d.u16.4 hr8.x, g[2], r5.y, r5.w     (global f16vec4 -> half regs)
stl.u16 l[r4.w], hr8.x, 4                          (to shared, 16-bit)
ldl.u16 hr10.x, l[r3.x], 4                         (from shared)
mad.f16 ...                                        (math)
```

The covs are only at the end, for the FP32 output. Before the patch, mediump with FP32 storage (`m32`) has 40 covs. (The disassembler prints the half destinations of cat6 as `r`, cosmetically.)

### Upstreamability

- **Patch 1 (ir3)** is small, hardware-verified and a5xx-only. It could go upstream as is, with the ISA probe results as justification.
- **Patches 2–6** are a new GL extension in core GLSL. Upstream would want three things first:
  - the remaining spec rules enforced (swizzles, vector subscripts, default-block uniform structs);
  - Piglit tests;
  - a decision on whether a driver cap per screen is right. Possibly it should also come on for other drivers that have 16-bit storage (radeonsi, iris, zink with VK_KHR_16bit_storage), which this does not touch.
  
  The extension has no GLES CTS coverage that I could find (dEQP-GLES31 has none).
- **Patch 7** fixes real silent hangs and zero outputs, including dEQP failures on stock (below). The budget constant, however, comes from measurements on one chip, the A506. Larger a5xx parts (a530/a540) may have a bigger register file, so upstream would want either per-GPU values in `freedreno_devices.py` or measurements on those parts. As written it is safe there (it only spills more) but possibly pessimistic.
- Nothing has been posted upstream.

## 3. Register footprint on a5xx (patch 7)

**Symptoms.** On stock Mesa:

- compute kernels with `barrier()` and 128 invocations hang the GPU when they use more than 16 full registers, or 16 full plus any half registers. This is the gpu-compute stream's `E40801C3` faults and "≤ 16 full registers" rule.
- the kokoro-gpu stream's bigger fragment kernels write all zeros (unrolled taps: 48 full + 48 half registers; G = 2: 24 full + 35 half at double threadsize).

**Cause.** a5xx has separate half and full register files in the ISA, but half registers take space in the same per-SP register file, at half the cost of a full vec4. ir3 on a5xx does not account for this in three places:

- it leaves half registers out of `regs_count` (the double-threadsize choice; `ir3.c`);
- it lets RA fill both files to 48 vec4 independently;
- `calc_limit_pressure_for_cs_with_barrier()` has a `TODO` for exactly this non-merged case and does nothing.

**Rule.** Every case measured fits this rule, and every failing case breaks it:

> threads in flight × (full vec4 + half vec4 / 2) ≤ 2048

Threads in flight are the workgroup for compute with a barrier, rounded up to whole waves, or one wave of 32 (64 at double threadsize) otherwise. Data (`results/raw-16bit-20261101-0912.log`, `-0916`, kokoro repro `-1033`):

| Shader | threads | full | half | full + half/2 | × threads | stock |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| GEMM f32 RM8 | 128 | 16 | 0 | 16 | 2048 | runs |
| GEMM h32 RM8 | 128 | 16 | 2 | 17 | 2176 | **hangs** |
| GEMM f32 RM4 | 128 | 24 | 0 | 24 | 3072 | **hangs** |
| GEMM m32 RM8 (double) | 128 | 6 | 22 | 17 | 2176 | **hangs** |
| GEMM f32/h32 RM8 | 64 | 24 | 0/2 | 24/25 | 1536/1600 | runs |
| GEMM m32 RM4 (double) | 64 | 6 | 48 | 30 | 1920 | runs |
| GEMM hmix RM16 | 64 | 24 | 38 | 43 | 2752 | **hangs** |
| FS conv unrolled | 32 | 48 | 48 | 72 | 2304 | **zeros** |
| FS conv G2 (double) | 64 | 24 | 35 | 41.5 | 2656 | **zeros** |
| FS conv looped | 32 | 9 | 15 | 16.5 | 528 | runs |

**Fix.**

- Count half registers at half cost in `regs_count` on a5xx, as on a6xx.
- In RA, split the per-thread budget (64 vec4 for one wave, 2048 / workgroup threads for compute with a barrier) between the two files once the half pressure is known, and clamp both file sizes.

Shaders over the budget now spill (a5xx has private memory) instead of hanging or writing nothing.

**Effect** (`results/deqp-*`, `results/raw-16bit-20261101-1033.log`):

- `dEQP-GLES31.functional.compute.shared_var.work_group_size.mat4_{128_1_1,1_128_1,1_1_64}` hang on stock and pass with the patch.
- The mediump GEMM at 128 threads goes from a hang to 13.3 GFLOP/s.
- The kokoro-gpu conv kernels go from all zeros to correct (err 0.003–0.007 against |ref| 1.41).

**But it does not make them fast.** The unrolled FS conv runs at 6.45 GFLOP/s and G = 2 at 4.3, against 6.46 for the looped kernel that already worked. They now fit by spilling, and the budget is real hardware: about 2048 vec4 per SP, so only 4 waves of 16 registers. For kokoro-gpu this means the faster-looking variants were never going to be faster on this GPU. Kernels have to stay small: ≤ 16 full-equivalent registers at 128 threads, ≤ 64 per single wave. `max_waves` in the ir3 statistics now reads 0–2 for such shaders. That is cosmetic, since fd5 does not program it.

## 4. Results

Correctness and conformance:

- **Own tests** (`gles16 test`, `results/test-16bit-*.log`): 15/15 pass.
  - These cover: float16 load and store (subnormal, ±0, inf, max); f16vec4 load and f16vec2 store; odd-index 16-bit stores that leave neighbours untouched; int16 sign and zero extension; int → int16 truncation; a std430 struct mixing 16- and 32-bit members (offsets 0/4/8/14, stride 16); std140 UBO `f16vec4[]` (16-byte stride) and packed 16-bit scalars; 6 compile-rule checks (5 rejects, 1 accept).
  - `float16_t(float)` rounds toward zero on this GPU (`cov.f32f16`): 125/256 values are 1 ulp off from round-to-nearest-even. The spec leaves the rounding mode open.
- **dEQP-GLES31** (VK-GL-CTS `opengl-es-cts-3.2.9.3`, surfaceless, pbuffer 256x256; `scripts/build-deqp.sh`, `scripts/device-deqp.sh`):

  | Group | stock 26.2.6 | patched |
  | --- | --- | --- |
  | functional.ssbo.* (2061) | 2061 pass | 2061 pass |
  | functional.compute.* (195) | 188 pass, 7 fail (3 hangs) | 191 pass, 4 fail |
  | functional.program_interface_query.shader_storage_block.* (92) | 29 pass, 63 not supported | same |
  | functional.program_interface_query.buffer_variable.* (1313) | 1046 pass, 267 not supported | same |
  | functional.layout_binding.ssbo.* (10) | 5 pass, 5 not supported | same |
  | functional.shaders.builtin_functions.precision.* (777) | see below | see below |

  The 4 compute failures on both are `indirect_dispatch.*.multi_dispatch*`, which predate these patches. The 3 fixed ones are the `shared_var.work_group_size.mat4_*` hangs. dEQP has no 16-bit storage cases for GLES.

GEMM sweep: `results/gemm-16bit-20261101-1005.log` (patches 1–7 before the all-stages part of patch 7, see note). `C = A·B`, FP32 output, error = max |C − ref| on 24 sampled rows; "vs fp32" uses the FP32 inputs, "vs fp16 in" the FP16-rounded inputs. Variants:

- `f32`: FP32 storage, FP32 math. The st64r8k32 kernel of gpu-compute.
- `m32`: FP32 storage, mediump math. The old 0.75x path.
- `h32`: FP16 storage, FP32 math and accumulation.
- `h16`: FP16 storage, FP16 math and accumulation.
- `hmix`: FP16 storage, FP16 products summed over each 32-long K block, FP32 across blocks.

Tile A has 128 invocations and 8 rows each (the FP32 optimum). Tile B has 64 invocations and 16 rows each, where `h32` fits without spilling. GFLOP/s:

| Shape (M x K x N) | f32 A | m32 A | h16 A | h32 A | f32 B | h32 B | h16 B | hmix B |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 512³ | 13.4 | 12.4 | 12.8 | 4.8 | 10.5 | 10.5 | 8.5 | 8.3 |
| 1024³ | 13.9 | 13.3 | 13.3 | 4.9 | 10.9 | 10.9 | 8.8 | 8.6 |
| 2048³ | 13.5 | 13.1 | 13.2 | 4.5 | 10.6 | 11.0 | 8.8 | 8.6 |
| 128 x 896 x 3584 | 13.2 | 12.3 | 13.1 | 4.7 | 10.2 | 10.9 | 8.7 | 8.5 |
| 384 x 896 x 3584 | 13.3 | 12.6 | 13.3 | 4.8 | 10.3 | 11.0 | 8.8 | 8.7 |
| 128 x 3584 x 896 | 13.5 | 12.8 | 13.3 | 4.7 | 10.7 | 10.8 | 8.7 | 8.6 |
| 4000 x 4320 x 480 | 13.3 | 12.3 | 12.8 | 4.1 | 10.2 | 10.4 | 8.3 | 8.2 |

Max error at 1024³ (|C| ≈ 45):

| f32 | m32 / h16 (FP16 accumulation) | h32 (FP16 inputs, FP32 math) | hmix |
| ---: | ---: | ---: | ---: |
| 6e-5 | 0.48 / 0.39 | 0.011 (vs the FP16 inputs: 5e-5) | 0.047 |

With FP16 accumulation the error grows with K: 1.3–1.9 at K = 3584–4320 (|C| ≈ 80–90). On stock Mesa (`results/raw-stock-20261101-1020.log`), `m32` on tile A hangs (output never written) and f32 is the same 14.0.

What this shows:

- **FP16 storage costs nothing and saves nothing in time.** `h32` equals `f32` at the same tile. Its FP32 math needs one extra half vec4 for the conversion, which pushes the 128-thread tile over the register budget, so it spills (4.4–4.9). Its best is tile B, 10.3–11.2, which is 0.75x of the FP32 optimum. The kernel is issue/latency bound (gpu-compute: about 11% of peak), so halving the bytes does not matter. Halving weight memory does matter for residency on a 2 GB device.
- **FP16 math does not beat FP32** even with no conversions in the loop. On tile A, `h16` gets 12.8–13.6 against `f32` 13.3–14.4 (0.9–0.95x, up from gpu-compute's 0.75x). On a5xx, double threadsize gives 16-bit ALU ops double rate, but this kernel is not ALU-bound.
- **Mixed precision (`hmix`)** is accurate (about 0.1% of |C|) but 8.2–8.7 GFLOP/s.

The dispatch is split into ≤ 0.05 GFLOP chunks, each flushed, with at least one 64-column tile. With 0.25 GFLOP chunks, long runs (≥ 1 s) were sometimes killed by hangcheck. That happens when the GPU starts at the 19.2 MHz devfreq floor, where a 0.25 GFLOP chunk takes longer than the 500 ms hangcheck.

**Vocoder-shaped conv1d** (`results/conv-16bit-20261101-1002.log`): 512 → 512 channels, kernel 7, "same" padding, L = 24000 (1 s at 24 kHz), 88 GFLOP. It runs as an implicit GEMM (M 512, K 3584, N 24000, B read straight from the padded input; no im2col buffer), one pass:

| Variant | Tile | GFLOP/s | ms | max err (|ref| 3.6) |
| --- | --- | ---: | ---: | ---: |
| f32 | A | 12.6 | 6975 | 8e-6 |
| m32 | A | 12.2 | 7244 | 0.057 |
| h16 | A | 12.3 | 7146 | 0.057 |
| f32 | B | 9.8 | 9019 | 8e-6 |
| h32 | B | 9.9 | 8896 | 1.1e-3 (vs fp16 in 7e-6) |
| h16 | B | 8.4 | 10487 | 0.057 |
| hmix | B | 8.2 | 10684 | 3.4e-3 |

A layer this size is 88 GFLOP per second of audio and takes 7 s on the GPU. The task's 48 GFLOP per second of audio at about 12.5 GFLOP/s is about 3.8 s per second of audio, **3.8x slower than real time**. That is before any copies, and with the CPU's memory bandwidth shared (gpu-compute measured the decoder slowing by 20% while the GPU runs). FP16 storage would let the vocoder's weights and activations sit in half the memory, but it does not make the GPU fast enough. For the vocoder, the CPU path or a smaller model stays the better plan unless a fundamentally better kernel is found. The ceiling is the same 13–14 GFLOP/s for every kernel shape tried here and in gpu-compute.

Note on numbers: the GEMM and conv tables were measured with patches 1–6 plus the compute-only first version of patch 7. The final patch 7 also counts half registers outside compute. The check run with the final build (`results/raw-16bit-*` after 10:30) matches within noise. See [Reproduce](#reproduce).

## Build

- **Base and sources.** Mesa `downloads/mesa`: a shallow clone of tag `mesa-26.2.6` from gitlab.freedesktop.org (HTTPS), with worktrees `work/src-stock` and `work/src-16bit`.
- **Sysroot** (`work/sysroot`):
  - glibc 2.43 and libstdc++ 16 from `streams/asr/work/sysroot` (Debian arm64, SHA-256 checked by `make-sysroot.sh`), which match the device;
  - libdrm 2.4.134, zlib, expat and zstd headers and libraries copied from the device itself (`tar` over adb, the device's `pacman -Qlq libdrm` headers).
- **Cross build.** Host clang 22 + lld, meson 1.12.1 with mako in `work/venv` (uv). Only freedreno Gallium, EGL (surfaceless), GLES2/3 and the GLSL compiler are built: no LLVM, no glvnd, no GBM, no platforms. Build time is about 3 min. The prefix is 30 MiB.
- **Host build.** `--host` builds an x86_64 copy with the freedreno noop **drm-shim**. Run as `FD_GPU_ID=510`; the shim has no 506, but the compiler is the same a5xx one. It compiles and disassembles the shaders on the laptop without the device.

Scripts (in `scripts/`):

- `build-mesa.sh [--stock|--host] [--dev] [--clean]`: resets `work/src-16bit` to `8e87a50`, `git am`s `patches/`, and builds into `work/stage-16bit/opt/mesa-16bit`.
- `build-tests.sh`: `build/gles16` and `build/ssbo-probe` (dlopen `libEGL.so.1`).
- `build-deqp.sh [fetch]`: deqp-gles31. Externals are pinned as in `external/fetch_sources.py`: zlib and libpng tarballs SHA-256 checked, git dependencies at the pinned commits over ssh. glslang needs `-include cstdint` with libstdc++ 16, and `DE_CPU` must be forced to ARM_64 when cross-compiling.
- `deploy-mesa.sh [16bit|stock] | --remove`: puts `/opt/mesa-<variant>` and `/opt/mesa16-tests` on the device.
- `device-isa-probe.sh`, `device-test.sh test|gemm|conv|raw`, `device-deqp.sh push|run`: all take the device lock and log to `results/`.

Use on the device: `. /opt/mesa-16bit/env.sh`, which sets `LD_LIBRARY_PATH=/opt/mesa-16bit/lib` and a separate shader cache directory. Then `/opt/mesa16-tests/build/gles16 info`.

## Reproduce

```sh
cd streams/gpu-mesa16
scripts/build-mesa.sh --stock && scripts/build-mesa.sh      # 26.2.6 and 26.2.6 + patches/
scripts/build-tests.sh
scripts/deploy-mesa.sh stock 16bit
scripts/device-isa-probe.sh stock                           # section 1
scripts/device-test.sh test                                 # 15 checks
scripts/device-test.sh gemm                                 # about 10 min, GEMM table
scripts/device-test.sh conv                                 # about 1 min, conv1d table
scripts/build-deqp.sh fetch && scripts/build-deqp.sh && scripts/device-deqp.sh push
scripts/device-deqp.sh run 16bit 'dEQP-GLES31.functional.ssbo.*' 'dEQP-GLES31.functional.compute.*'
```

## Left on the device

- `/opt/mesa-16bit` (30 MiB, this series), `/opt/mesa-stock` (30 MiB, unpatched 26.2.6), `/opt/mesa16-tests` (test programs, probes, and a copy of straylight-voice's `sg-bench` for the kokoro repro), `/opt/mesa16-deqp` (18 MiB).
  - Nothing else was touched. The system still has no Mesa and the UI is unaffected.
  - Remove all of it with `scripts/deploy-mesa.sh --remove`.
- GPU hangchecks were logged in dmesg during the fault experiments (the hangs in section 3). They were all recovered by the kernel, with no lasting effect.

## Downloads

All are git-ignored, under `downloads/`:

- `mesa/` (git, tag `mesa-26.2.6`);
- `vk-gl-cts/` (git, tag `opengl-es-cts-3.2.9.3`, with externals at the pinned commits);
- `cts-ext/` (zlib-1.2.13 and libpng-1.6.27 tarballs, SHA-256 as in the CTS's `fetch_sources.py`).
