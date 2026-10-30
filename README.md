# Lenovo ThinkSmart View on mainline Linux

Mainline Linux 7.x (64-bit) with Arch Linux ARM on the Lenovo ThinkSmart View CD-18781Y (Qualcomm APQ8053 / MSM8953), replacing Android. Goal and definition of done: [`GOAL.md`](GOAL.md).

| Path | What |
| --- | --- |
| [`GOAL.md`](GOAL.md) | Goal, done criteria per device, constraints, milestones, decisions |
| [`FLASHING.md`](FLASHING.md) | Stage A flashing runbook (EDL, lk2nd, system image, rollback) |
| [`devices/`](devices/README.md) | Per-device analysis: briefs and findings |
| `kernel/` | `build.sh`, config fragment, and patches on msm8953-mainline `barni2000/7.3/develop` |
| `lk2nd/` | Build script and notes for lk2nd (`msm8916-mainline/lk2nd`, `lk2nd-msm8953`) |
| [`rootfs/`](rootfs/README.md) | Arch Linux ARM image build: USB gadget (NCM, ACM, adb), firmware extraction, boot splash |

Not in this repository, by design: Lenovo/Qualcomm firmware and anything extracted from it, device backups and raw captures, built images, downloads and third-party source trees. The scripts recreate them.

## Licence

MIT for the scripts and docs written here (see [`LICENSE`](LICENSE)). Patches to upstream projects (kernel device tree, adbd) and anything derived from upstream code keep their upstream licences. The ai& wordmark in `rootfs/assets/` and the images rendered from it belong to AI& and are not covered by the MIT licence.
