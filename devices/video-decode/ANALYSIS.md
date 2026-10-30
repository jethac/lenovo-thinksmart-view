# Video decode — ThinkSmart View CD-18781Y

## 1. Summary

Venus is the MSM8953 hardware codec block (`venus@1d00000`, decoder and encoder V4L2 subdevices). It works on this hardware: the prior 6.19.5 port decoded 1080p H.264 at 1.26× real time and 1080p HEVC at 5.74× on `/dev/video7`. The one hard limit is B-frames — every B-frame stream stalls at frame 0 for both codecs — and the current mainline tree does not enable the node at all, while upstream had to revert enabling Venus on a sibling SoC (`sdm632`) at 7.0.2. The work is therefore: enable it, pick up the per-device firmware, and prove whether the sdm632 revert reason applies to APQ8053.

## 2. Identity

- `venus@1d00000`, `compatible = "qcom,msm8953-venus"`, children `venus-decoder` and `venus-encoder`, with an OPP table and a `venus_mem` reserved region (`msm8953.dtsi:2110-2150`).
- Firmware `venus.mdt` + `venus.b00`-`b04` in the `modem` partition; hashes recorded in `../firmware-remoteproc/evidence/stock-firmware-sha256-20261030.txt`.
- Stock decodes through `OMX.qcom.video.decoder.{avc,hevc,vp8,vp9,mpeg2,mpeg4,h263,vc1,wmv,divx*}` (`evidence/stock-codecs-20261030.txt`), i.e. the firmware supports far more than the two codecs in scope.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| Node | `venus` enabled via vendor stack | node present, board DTS does **not** enable it | gap |
| Firmware | `/firmware/image/venus.*` | `venus.mdt` (driver default) | path only |
| FIRMWARE region | `venus_mem` reserved | `venus_mem` present in `msm8953.dtsi` | yes |
| Clocks / power | GCC Venus clocks, `venus` GDSC | inherited from `msm8953.dtsi` | yes |
| OPP | vendor pwrlevels | `operating-points-v2` from SoC dtsi | equivalent |

## 4. Stock behaviour

- Venus is driven by the vendor video stack (OMX/Codec2), so B-frames are handled by the firmware through a different interface than the V4L2 M2M one — Android never hits the B-frame wall.
- Stock also runs the **encoder**, which is what video calling uses.

## 5. Mainline state

- `venus` node and firmware plumbing exist in `msm8953.dtsi`; nothing enables it for this board.
- The known-good behaviour and the B-frame limit come from the 6.19.5 port, not from 7.1.3/7.3, so both need re-verification on the target kernel.
- `msm8953-mainline` carries branch `revert-247-7.0.2-venus` (`aa7947fd38ea`), whose only content is "Revert `arm64: dts: qcom: sdm632-fairphone-fp3: Enable venus`". So around 7.0.2 Venus was broken badly enough on sdm632 (same Venus generation) that enabling it had to be backed out. Whether that was a firmware-version, IOMMU or power-collapse problem is unrecorded; the branch has no driver change, so the driver is presumably fine and the DTS enable was the problem.
- On 7.3 the board DTS here still does not enable Venus.

## 6. Gap and plan

1. Enable `&venus` with `status = "okay"` and a firmware-name pointing at this device's blobs; install `venus.*` after the ADSP path is proven so two remoteprocs are not brought up at once.
2. Decode a no-B-frame H.264 1080p file with `ffmpeg -c:v h264_v4l2m2m` and confirm frame counts, not just "it started". Repeat for HEVC.
3. Reproduce the B-frame stall and capture the V4L2 event trace (`v4l2-ctl --log-status`, `dmesg`) so the failure is documented rather than repeated in folklore.
4. Find out whether the B-frame limit is firmware (this `venus.mdt` build) or driver DPB handling; a newer Venus firmware from another msm8953 build is a cheap test.
5. Test encode: `ffmpeg -c:v h264_v4l2m2m` on a test source, needed later for the camera/video-call path.
6. Session hygiene from the prior port: close and re-open the device between runs, and watch for stale-fd/DMA-fragmentation errors after repeated cycles.

## 7. Risks

- Venus and the ADSP both use PIL/secure memory; bringing both up in the wrong order can fail their loads.
- A failed Venus load can leave a secure region busy and stop the GPU zap shader from loading (same SCM path).
- B-frame stalls hang the player rather than erroring, which looks like a UI freeze.
- Venus shares DDR bandwidth with the display; sustained decode can cause panel underruns.

## 8. Open questions

- What exactly broke on sdm632 at 7.0.2 — IOMMU, power domain, or firmware?
- Is the B-frame failure firmware-version-specific, and does any msm8953 Venus firmware handle it?
- Is encode functional at all on mainline Venus, or only decode?
- Does `venus_mem` sizing in `msm8953.dtsi` match what this 800x1280 device needs?

## 9. Sources

- `../../ubuntu-thinksmart/research/video/analysis/venus-decode-findings-2026-06-05.md` (measured rates, B-frame failure, session requirements).
- `evidence/stock-codecs-20261030.txt`; `../firmware-remoteproc/evidence/stock-firmware-sha256-20261030.txt` (venus hashes).
- Mainline `arch/arm64/boot/dts/qcom/msm8953.dtsi:2110-2150`; `origin/revert-247-7.0.2-venus` = `aa7947fd38ea` fetched 2026-10-30.
- `video-decode/BRIEF.md`.
