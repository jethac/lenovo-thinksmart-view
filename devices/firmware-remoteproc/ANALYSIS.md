# Remote processors and firmware — ThinkSmart View CD-18781Y

## 1. Summary

Nothing here needs inventing: every blob mainline wants already exists on this unit, and 157 of the 158 files extracted from the backed-up `modem` partition hash-identically to the live device. What mainline actually needs is small — the ADSP image (audio, and the sensor/SSC side), the Venus video firmware, the Adreno zap shader, the camera CPP firmware, and the QCA9379 Wi-Fi/BT blobs. Everything else in `/firmware/image` (`modem.*`, `cmnlib*`, `widevine`, `smplap*`, `securemm`, `mdtp`, `gptest`, `dhsecapp`, `qmpsecap`, `isdbtmm`) belongs to the bootloader or to Android and is not requested by 7.3. The extraction path and the destination layout are settled below and are reproducible from the backup images alone.

## 2. Identity

`/firmware` is a FAT16 filesystem on partition p1 (`modem`, 88 MiB), `/dsp` is ext4 on p12. Live hashes of everything under both are in `evidence/stock-firmware-sha256-20261030.txt` (159 files) and `evidence/stock-dsp-sha256-20261030.txt` (20 files).

Blobs mainline will request, with the requesting driver:

| File group | Requested by | Mainline name |
| --- | --- | --- |
| `adsp.mdt`, `adsp.b00`-`b14` | `qcom_q6v5_pas` (`qcom,msm8953-adsp-pil`, default `.firmware_name = "adsp.mdt"`, no `adsp_dtb` for this resource) | `adsp.mdt` |
| `venus.mdt`, `venus.b00`-`b04` | Venus (`qcom,msm8953-venus` + venus `firmware-name`) | `venus.mdt` |
| `a506_zap.mdt`, `.b00`-`.b02` | `&gpu_zap_shader` | `qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt` |
| `a530_pfp.fw`, `a530_pm4.fw` | Adreno | `qcom/a530_pfp.fw`, `qcom/a530_pm4.fw` |
| `cpp_firmware_v1_5_0.fw` (only this one is loaded on stock, boot log 7.12 s) | CAMSS CPP | `qcom/` |
| `athwlan.bin`, `bdwlan30.bin`, `qwlan30.bin` | `ath10k_sdio` | as-is into the `ath10k` directory |
| `btfwnpla.tlv`, `btnvnpla.bin` | `btqca` | as-is into the `qca` directory |
| `cpe_9335.*` | `qcom_q6v5_pas` / CPE | only if CPE audio is used |

Not needed by mainline: `modem.mdt` (no modem), `cmnlib*`/`cmnlib64`/`lksecapp`/`keymaster` (loaded by `aboot`/TZ from their own partitions), `widevine`, `smplap32/64`, `securemm`, `mdtp`, `gptest`, `dhsecapp`, `qmpsecap`, `isdbtmm`, and `/dsp` (that is the ADSP's *filesystem* of codec/`fastrpc` shared libraries, mounted by Android's `adsprpcd`, not firmware — but see §4).

## 3. Wiring / layout

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| ADSP firmware path | `/firmware/image/adsp.*` (`/firmware` = p1) | `adsp.mdt` in `/lib/firmware` | path differs |
| Zap shader | `/vendor/firmware/a506_zap.*` | `qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt` | path differs, name already in DTS |
| Venus | `/firmware/image/venus.*` | `venus.mdt` | path differs |
| Wi-Fi/BT | `/firmware/image/{athwlan,bdwlan30,qwlan30,btfwnpla,btnvnpla}` | `ath10k/`, `qca/` | names must be adapted |
| `mpss`/`wcnss` regions | present in stock DT | deleted in mainline DTS | expected |

Firmware is signed per OEM, so these must come from this unit's partitions, never from `linux-firmware`.

## 4. Stock behaviour

- The ADSP is started by the vendor `msm-adsp-loader` at early boot (`qcom,adsp-loader`, `qcom,adsp-state`), with `adsp_fw_region` reserved memory.
- `/dsp` is mounted and `adsprpcd`/`fastrpc_shell_0` serve the DSP codec modules (`AdacDecoderModule`, `Dolby*`, `HeaacDecoderModule`, `fluence_voiceplus_module` and friends). Mainline does not need these for basic audio, but the Fluence voice-plus module is the echo-cancellation path and may matter for `echo-cancellation/`.
- `verinfo/ver_info.txt` in the `modem` partition is rewritten at runtime: it is the only file whose backup and live hashes differ (`evidence/backup-vs-live-hash-check-20261030.txt`). Take it from the live device if it matters, from the backup otherwise.
- No `rmtfs` is required for this board: there is no modem to serve storage to. The mainline DTS already deletes `rmtfs@f2d00000`.

## 5. Mainline state

- `&gpu_zap_shader` has the correct device-specific `firmware-name`.
- `&mpss` has `mba`/`mpss` deleted; `wcnss` node and `wcnss_fw_mem` are deleted.
- ADSP, Venus, CPP and the Wi-Fi/BT blobs have **no** firmware present in the tree — the DTS relies on driver defaults, which is fine for names but nothing ships the files.
- No extraction script, no hashes, no destination layout existed before this analysis.

## 6. Gap and plan

1. Extraction, from the backups only (proven): `zstd -dc partitions/modem.img.zst > modem.img`, then `evidence/fat16-extract.py modem.img out/`. Verified: 157/158 files match the live device byte for byte.
2. `/dsp` for the codec modules, from `partitions/dsp.img.zst` via `debugfs -R "dump <path> <out>"` (ext4, no mount rights needed).
3. Install to `/lib/firmware` exactly as the table in §2 says, with a `SHA256SUMS` beside it and a copy of the check file, so a later rebuild can prove provenance.
4. Add `firmware-name` properties for ADSP and Venus where the default name is not what we ship, or ship the default names — pick one and be consistent.
5. Test each consumer separately: GPU zap (any `glxgears`), Venus (`v4l2-ctl` H.264 decode), ADSP (audio playback), Wi-Fi (`ath10k_sdio` probe), BT (`btqca` load).
6. Keep every blob out of public git; ship them as a tarball.

## 7. Risks

- A wrong or truncated `adsp.mdt` makes the ADSP crash-loop and takes audio, and possibly sensors, with it.
- The zap shader is signed against the GPU's secure state; a mismatched one leaves the GPU unusable but does not brick.
- `/firmware` is FAT16 with read-only-ish semantics on stock; writing to it is optional, copying out is not.
- Licensing: Lenovo/Qualcomm property. Keep out of public repos, and note that the official Zoom package ships `adspso.bin` (a whole-partition image), not the individual files.

## 8. Open questions

- Does the ADSP need `adsp_dtb.mdt` on this SoC revision? The driver does not ask for one here; confirm on first boot rather than assume.
- Which `bdwlan`/`board-2.bin` variant `ath10k_sdio` wants for QCA9379 — `bdwlan30.bin` exists, `board-2.bin` does not.
- Is `cpe_9335` (CPE audio) needed for the `qcom,msm8953-adsp-pil` audio topology, or is the ADSP enough?
- Does `fluence_voiceplus_module` in `/dsp` need to be loaded for AEC, or does PipeWire's WebRTC AEC make it moot?

## 9. Sources

- `evidence/stock-firmware-sha256-20261030.txt`, `evidence/stock-dsp-sha256-20261030.txt`, `evidence/backup-vs-live-hash-check-20261030.txt`, `evidence/fat16-extract.py`.
- `../stock/stock-firmware-listings-20261030.txt`; `../backup-20261029/partitions/{modem,dsp}.img.zst`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:8-20,176-180`; `msm8953.dtsi:1960,2111,2254,3081`; `drivers/remoteproc/qcom_q6v5_pas.c:745-770,1016-1027,1540`; `drivers/media/platform/qcom/venus/firmware.c`.
- `../../official-firmware/README.md`; `firmware-remoteproc/BRIEF.md`.
