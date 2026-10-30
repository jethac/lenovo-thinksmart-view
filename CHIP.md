# The chip: Qualcomm APQ8053

What is specific about the SoC in this ThinkSmart View (serial `HUA0BMNX`), and what of it is usable from mainline Linux. Each fact says where it comes from:

- **measured**: read on this unit (EDL, the running 7.3 kernel, or the as-received Android);
- **source**: read from the 7.3 tree, Lenovo's firmware, or stock device tree;
- **inferred**: deduced, not directly observed.

## Identity

| | Value | From |
| --- | --- | --- |
| Part | APQ8053: the MSM8953 (Snapdragon 625 family) with no modem | measured (`/sys/devices/soc0/machine`, EDL "CPU detected") |
| SoC ID | 304 (`QCOM_ID_APQ8053`), revision 1.1 | measured (`soc0/soc_id`, `soc0/revision`) |
| EDL HWID | `0x000660e160008000`: MSM_ID `0x000660e1`, OEM_ID `0x6000`, MODEL_ID `0x8000` (MSM8953 proper is `0x000460e1`) | measured (EDL Sahara) |
| OEM PK hash | `b9eca30dfea4693497b6ac7eec81d006967281e259eb9ac239f9ce6dabb70c14` | measured (EDL); decides which firehose programmer the boot ROM accepts |
| Chip serial | `0xa9f689e3` (2851506659), the same value from EDL and `soc0/serial_number` | measured |
| Board | `qcom,board-id = <0x1010520 0>`, Lenovo board file `apq8053-lite-dragon-v2.0.dtsi` | source (7.3 DTS, stock DT) |

## CPU

- 8x **Arm Cortex-A53 r0p4** (MIDR implementer `0x41`, part `0xd03`, revision 4), in **two clusters of four** (`cluster_id` 0 and 1). Each cluster shares its own L2. measured
- In-order, dual-issue, 8-stage pipeline. 128-bit NEON datapath, split into 64-bit halves for most operations. source (Arm Cortex-A53 TRM)
- Frequencies on this unit's speed bin: 652.8 / 1036.8 / 1401.6 / 1689.6 / 1804.8 MHz (stock). The mainline OPP table also lists 2016 and 2208 MHz for other bins, selected by the `cpu_speed_bin` fuse. Voltage comes from closed-loop **CPR4** with temperature compensation. measured / source
- Currently runs at about 1.23 GHz on mainline: frequency scaling logs `Failed to set OPP config`. This is being fixed. measured
- Boots at **EL1**: Lenovo's `aboot` does not hand over EL2 (`kvm: HYP mode not available`), so no KVM or virtualisation. measured
- PSCI 1.0 (SMCCC 1.0, OS-initiated mode supported). `failed to set PC mode: -1` is a firmware quirk. cpuidle uses `psci_idle` with two states. measured
- Kernel side: KPTI is forced on because KASLR is on (the A53 is not affected by Meltdown, so `nokaslr` removes it), and the ARM erratum 845719 workaround is enabled. measured

### Instruction set

**ARMv8.0-A**, with both AArch64 and AArch32 at EL0 and EL1. measured (`32-bit EL0 Support`, `32-bit EL1 Support`)

AArch64 features reported (`/proc/cpuinfo`): `fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid`. measured

| Extension | Present | What it means here |
| --- | --- | --- |
| FP / AdvSIMD (NEON), 128-bit | yes | The main compute path: FP32 and integer SIMD. FP64 SIMD too |
| AES, PMULL | yes | Hardware AES and GF(2^128) multiply: fast TLS (AES-GCM) for network traffic |
| SHA1, SHA2-256 | yes | Hardware hashing |
| CRC32 | yes | zlib/zstd checksums, ext4 metadata |
| `evtstrm`, `cpuid` | yes | Generic timer event stream; userspace can read ID registers |
| LSE atomics (ARMv8.1) | no | Atomics use load/store-exclusive loops |
| RDM (`sqrdmlah`, ARMv8.1) | no | |
| FP16 arithmetic (ARMv8.2) | no | Half-precision only as a storage format: convert to FP32 to compute |
| Dot product `sdot`/`udot` (ARMv8.2/8.4) | no | No 4-way int8 dot product. Quantised ML kernels use `smull`/`smlal`/`sadalp` chains instead, about 4x the instructions per int8 MAC |
| I8MM, BF16, SVE/SVE2, SME | no | |
| PAC, BTI, MTE | no | |
| Crypto SM3/SM4, SHA3, SHA512 | no | |

AArch32 (A32/T32): ARMv8 AArch32 with VFPv4, NEON, AES/SHA1/SHA2/CRC32, `idiva`/`idivt`, LPAE. As-received Android ran a 32-bit kernel and userspace on this. measured (stock `/proc/cpuinfo`)

## Memory

- 2 GiB LPDDR3. 1.99 GiB visible to Linux, because the mainline device tree drops the modem's reserved regions (about 116 MiB freed). measured (`MemTotal 1988100 kB`)
- Bandwidth: single-channel 32-bit LPDDR3 (about 7.5 GB/s peak if it runs at 933 MHz). inferred; to be measured. For token-by-token model decoding this, not compute, is the limit: each output token reads the decoder weights once.
- Reserved regions on mainline: `adsp@8d600000`, `venus@91400000`, `zap@95000000`, `qseecom@85b00000`, `smem@86300000`, `gps@93000000`, `cont-splash@90001000`, `dfps-data@90000000`. measured

## GPU: Adreno 506

- `qcom,adreno-506.0`, 19.2 to 650 MHz OPP table, identical to stock's power levels. source
- Mainline: `msm` DRM plus Mesa freedreno; `a530_pm4.fw`/`a530_pfp.fw` load; the signed zap shader is this device's own (`a506_zap.mdt`). measured
- OpenGL ES 3.x through freedreno. **No Vulkan**: Mesa's Turnip starts at Adreno 6xx. source
- OpenCL through Rusticl is not expected to support a5xx. inferred; to be checked on the device.
- Display controller: DPU hardware revision `0x10100000`, one DSI. measured

## Other blocks

| Block | State on mainline | Notes |
| --- | --- | --- |
| ADSP (Hexagon) | running (`remoteproc0`, `adsp`) | Firmware `ADSP.8976.2.8.1-00076`, 2017-10-09 (the MSM8976 ADSP branch). measured. No HVX vector unit on this generation. inferred. Runs audio routing (Q6 AFE). FastRPC is built (`CONFIG_QCOM_FASTRPC=m`) but has no device-tree node; running our own code there would need Qualcomm-signed DSP images |
| Sensors subsystem (SSC) | not used | On stock the ADSP owns the sensor bus (TrustZone-protected BLSP). Mainline bit-bangs I2C on GPIO 6/7 instead: about 1 ms CPU per accelerometer read |
| Venus | not enabled yet | Hardware H.264/HEVC decode and encode. The prior port found that B-frames stall |
| CAMSS + CCI | SoC nodes only | CSIPHY0/2, CSID, CCI, CPP; no board nodes yet |
| Modem (MPSS) | absent | APQ part; mainline deletes its nodes and memory |
| WCNSS (Pronto) | unused | Wi-Fi/BT are an external QCA9379 instead. Stock still exposed WCNSS FM (`radio-iris`) |
| Crypto engine (`qcrypto`) | not used | The CPU's AES/SHA instructions are faster for normal TLS |
| USB | DWC3 at `0x7000000`, QUSB2 PHY, USB 2.0 high-speed only | No Type-C CC negotiation on this board. Role comes from straps (GPIO 12, and GPIO 5 as ID). The debug UART (BLSP1 UART2, 1.8 V) is wired to the USB-C connector's CC and SBU pins |
| PMICs | PM8953 + PMI8950 | PMI8950 provides WLED (4 strings), LAB/IBB for the panel, the PON block (volume-down on `resin`; no power key wired), the charger (no battery fitted) and a Type-C block that stays inert |

## Boot chain

PBL (boot ROM; EDL `05c6:9008`, Sahara v2) → SBL1 → RPM, TrustZone, devcfg → `aboot` (Lenovo LK, **locked**: `devinfo` unlock flags 0) → **lk2nd** in `boot` → `extlinux.conf` on an ext2 partition inside GPT `system` → Linux.

- `aboot` verifies boot images against the certificate embedded in the image. On mismatch it logs `Keystore verification failed! Continuing anyways…` and boots anyway, which is why AOSP-test-key-signed images (LineageOS's, and our lk2nd) boot on a locked unit. inferred from strings in `aboot`; consistent with what boots
- EDL programmer: Lenovo's `prog_emmc_firehose_8953_ddr.mbn`, `BOOT.BF.3.3-00228`. Reads at about 42 MB/s, writes at about 30 MB/s over USB 2.0. `adb reboot edl` from Linux reaches it; so do Vol+ and Vol- held while plugging in the barrel jack. measured

## What is sitting there unused

For on-device speech (recognition in, synthesis out), roughly in order of payoff:

1. **The CPU frequency fix.** 1.23 GHz to 1.8 GHz is about 1.46x on everything. In progress.
2. **NEON, used well.** No dot product means the quantisation format matters: formats whose kernels are plain `smull`/`smlal` or FP32 NEON (Q4_0, Q8_0) can beat the K-quants on this core. Thread placement across the two clusters matters too, because each has its own L2. To be measured.
3. **Memory bandwidth, spent carefully.** Smaller weights per token (lower-bit quantisation of the decoder) speed up decoding almost linearly; compute tricks do not.
4. **The GPU for compute-bound parts.** The speech encoder processes the whole utterance at once (large matrix multiplies, compute-bound), unlike the decoder. OpenGL ES compute shaders on the Adreno 506 could take that part. There is no ready framework for it here (no Vulkan, likely no OpenCL), so this means writing custom shaders. Possible, not cheap.
5. **The ADSP.** Already running, but without HVX and with signed-code requirements, it is not a practical compute target. Its stock audio features (Fluence echo cancellation and noise suppression) depend on Qualcomm's proprietary audio stack, which mainline does not have.
6. **Small kernel wins.** `nokaslr` drops forced KPTI (fewer syscall and page-fault costs); zram for memory pressure; transparent huge pages for large model mappings. Each small, each to be measured.

Not useful for this: Venus (video only), the crypto engine, the WCNSS block, the modem.
