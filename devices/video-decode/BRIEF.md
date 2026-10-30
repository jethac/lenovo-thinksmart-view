# Video decode

## What this is

Venus, the hardware video codec block, through V4L2 memory-to-memory.

## Done when

H.264 and HEVC 1080p decode through V4L2 in a player (mpv or GStreamer), and encode is either working or documented as not.

## Known so far

- rickx (6.19.5): H.264 1080p at 1.26x real time, HEVC 1080p at 5.7x; B-frames not supported. See `../../ubuntu-thinksmart/research/video/analysis/venus-decode-findings-2026-06-05.md`.
- msm8953-mainline has a branch named `revert-247-7.0.2-venus`. Something about Venus changed or broke around 7.0.2. Find out what.

## Stock capture

- Venus firmware (`venus.mdt` and `.bNN`) with hashes.
- Stock codec list: `/vendor/etc/media_codecs*.xml`, and supported profiles and levels.

## Questions

- State of Venus for msm8953 in 7.3, and what the 7.0.2 revert is about.
- Why B-frames fail (driver, firmware version, or a known Venus v4 limitation).
- Encode support for the camera pipeline (useful for video calls).

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
