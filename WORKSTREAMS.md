# Workstreams

Parallel lines of work on the ThinkSmart View after the first Linux 7.3 boot. Each has a directory under `streams/<name>/` with its own `NOTES.md` (status, findings, what is on the device, what is left). `GOAL.md` is still the definition of done; `devices/<name>/ANALYSIS.md` is the starting evidence.

| Stream | Scope | Kernel patches | Depends on |
| --- | --- | --- | --- |
| `wifi` | QCA9379 `ath10k_sdio`: firmware/board file, MAC, regulatory (JP), GTK rekey source fix, join the home network, NTP | `patches-wip/wifi/`, numbered `01xx` | Wi-Fi PSK from the user |
| `cpufreq` | CPU frequency scaling (`Failed to set OPP config`), speed bin, CPR, thermal zones and policy | `patches-wip/cpufreq/`, `02xx` | none |
| `speaker` | TAS5782M driver with Lenovo's DSP register patch, ASoC routing, PipeWire/UCM, safe volume | `patches-wip/speaker/`, `03xx` | none |
| `camera` | S5KC505A: reverse engineering of the vendor library, CAMSS/CCI board nodes, sensor driver, libcamera | `patches-wip/camera/`, `04xx` | none to start |
| `stage-b` | Repartition for Omarchy (`devices/storage-emmc`), then Omarchy via `omarchy-arm` | none expected | `wifi` (needs internet); user approval before any partition-table write |
| `idle-rotate` | Gravity-following ai& idle screen (`rootfs/scripts/idle-rotate/`) | none | none |
| `asr` | On-device speech recognition: Qwen3-ASR-0.6B (transcribe.cpp GGUF) and lighter baselines (sherpa-onnx, SenseVoice, Moonshine, whisper.cpp); GPU feasibility; benchmarks | none expected | `cpufreq` for final numbers; `stage-b` for storage |

## The device

One tablet, reached over the single USB cable: `adb -s feb0bd1f028e4cb0` (root shell) and `ssh jethac@172.16.42.1`.

- **Lock.** Every session that changes anything on the device, or needs it quiet for a measurement, runs under the lock: `flock -w 1800 /home/jethac/Projects/lenovo-8/.device.lock <command>` (or a script that takes it, like `kernel/deploy-to-device.sh`). Read-only peeks (`cat`, `dmesg`, `ls`) may skip it. Keep each locked session short; release between steps.
- **Leave it on the baseline.** When you release the lock, the device runs the baseline kernel (the accepted series in `kernel/patches/`, built in `kernel/build-7.3`) and the baseline userspace, unless your change has been accepted into the baseline. Test a kernel with `kernel/deploy-to-device.sh --reboot kernel/build-<stream>`, then put the baseline back with `kernel/deploy-to-device.sh --reboot` (or `--rollback --reboot`). Userspace experiments: undo them, or record them in your `NOTES.md` under "left on the device".
- **If it does not come back** after a reboot within three minutes: stop, do not retry, report. Recovery is EDL (`FLASHING.md`), done by the integrator only.
- **Never:** enter EDL, flash partitions, write the partition table, touch `persist`/`modemst*`/`fsg`/`devinfo`/bootloader partitions, or change the boot partition other than through `kernel/deploy-to-device.sh`. `stage-b` prepares partition changes but does not execute them without explicit approval relayed by the integrator.
- **Hardware hazards** in `devices/*/BRIEF.md` and `ANALYSIS.md` are binding (VCNL4200 IR LED; TAS5782M without its DSP patch at high volume; WLED limits; camera rail voltages; 1.8 V UART).

## The kernel

- Base tree: `kernel/linux-7.3` (msm8953-mainline `barni2000/7.3/develop`), with the accepted series in `kernel/patches/` applied by `kernel/build.sh`.
- **Each stream works in its own git worktree** of that tree and its own build directory, so streams never edit the same files:

  ```sh
  git -C kernel/linux-7.3 worktree add ../wt-<stream> -b ws/<stream> HEAD
  SRC=wt-<stream> OUT=build-<stream> EXTRA_PATCHES=patches-wip/<stream> kernel/build.sh
  ```

  Write changes as patch files in `kernel/patches-wip/<stream>/`, numbered in the stream's range, generated with `git diff` (or `git format-patch`) so they apply with `git apply`. Rebuild from them, not from hand edits.
- **Accepted** means: builds clean on top of the current `kernel/patches/`, tested on the device, results in `NOTES.md`. The integrator moves accepted patches into `kernel/patches/` and rebuilds the baseline.
- Config changes go into `kernel/config/lenovo-cd-18781y.config` only through the integrator; a stream that needs one says so in `NOTES.md` and uses a stream-local fragment meanwhile (`kernel/config/wip-<stream>.config`, applied by copying it into the worktree's `arch/arm64/configs/` and adding it to its own build invocation).

## The image

`rootfs/scripts/build-image.sh` is run by the integrator only (it needs the user's password in the environment). Streams that need something in the image change `rootfs/scripts/` (overlay, build steps) and say so in `NOTES.md`; they test on the running device by installing the same files over adb.

## Repository hygiene

The project is a public repository (`github.com/jethac/lenovo-thinksmart-view`). Streams do not commit or push; the integrator does.

- Never put into the repo: firmware or anything extracted from Lenovo/Qualcomm images, device captures (`stock/`, `*/evidence/`), secrets (passwords, PSKs, tokens), large binaries.
- Write docs, code comments and messages about the work itself, in plain project voice: what changed and why, not how or by what it was produced.
- Downloads go under the stream's directory in a `downloads/` subdirectory (ignored by git), verified where the source publishes checksums or signatures. Do not download anything onto the NAS. Use `git@github.com:` URLs for GitHub (HTTPS git hangs on this laptop).
