# Echo cancellation — ThinkSmart View CD-18781Y

## 1. Summary

Stock cancels echo on the **ADSP**: `persist.vendor.audio.fluence.speaker=true` and `…voicecall=true`, with the Fluence voice-plus module present in `/dsp`. Mainline has no ADSP audio path of its own beyond raw PCM, so AEC here has to be software — PipeWire `module-echo-cancel` with the WebRTC backend — and it has to cope with two clocks that are not locked to each other: playback goes out on quaternary MI2S to the TAS5782M, capture comes in on DMIC0. That clock relationship, not the AEC filter itself, is the thing that decides whether this can work.

## 2. Identity

- Stock: Fluence/ADSP; `ro.vendor.audio.sdk.fluencetype = none` (the SDK-level type is off, the vendor property is on), `vendor.voice.path.for.pcm.voip = true` (`evidence/stock-aec-props-20261030.txt`).
- Module present on the DSP filesystem: `/dsp/fluence_voiceplus_module.so.1` (see `../firmware-remoteproc/`).
- Mainline candidate: PipeWire `module-echo-cancel` (`aec_method=webrtc`), which is what `../../ubuntu-thinksmart/` and justhalfbit's design use.
- Hardware aid: the AFE loopback node exists on mainline (`/sys/kernel/debug/afe_loopback` with `codecs`, `dais`, `msm8953-snd-card-mtp`, `platforms`) — a debug aid, not a runtime AEC source.

## 3. Wiring and clocking

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| AEC engine | ADSP Fluence | none (software) | different |
| Playback path | quaternary MI2S → TAS5782M | same | yes |
| Capture path | DMIC0 → internal codec → ADSP | DMIC0 → codec → ALSA | yes |
| Clock domains | both under ADSP, single AFE clock root | separate DAI clocks (`pri/sec/quat MI2S` vs `dmic0`) | **risk** |
| Loopback aid | ADSP | `afe_loopback` debugfs | partial |

## 4. Stock behaviour

- Fluence runs only for speaker and voice-call use cases; `voicerec=false` means plain recording gets no EC. So the stock AEC is targeted at exactly our scenario (speaker playing, mic open) and is switched on by the audio HAL when the voice path is selected.
- Because both directions are inside the ADSP, playback and capture share one clock and one timestamp base — the hard part is solved by the DSP topology.
- Reference is the ADSP playback buffer itself, not a physical loopback.

## 5. Mainline state

- No DSP audio topology is ported; audio is plain ALSA/PipeWire over the codec and MI2S.
- PipeWire is the right place for the work: `module-echo-cancel` with `webrtc`, a virtual source that carries the playback stream as the reference.
- Drift is the open question: MI2S playback and DMIC capture are clocked from different AFE roots, so the reference and the mic will not stay sample-aligned; WebRTC AEC tolerates slow drift but not unbounded offset.
- Latency budget is unknown — nothing has measured round-trip playback-to-capture on mainline.

## 6. Gap and plan

1. Measure the clock relationship first: play a sweep, capture it, and look at the recorded length versus the played length after 60 s. Same root should give ~0 ppm; separate roots will show a visible drift. This single measurement decides whether the design is viable.
2. If drift is small, wire `module-echo-cancel` with `aec_method=webrtc`, `capture.props`/`playback.props` on the real devices, and a reference to the playback sink.
3. Measure round-trip latency (`paexec`/`pw-cat` impulse, or a short click with a scope on a breakout if easier) and set `aec_args` delay accordingly; check stability over 10 minutes, not one shot.
4. Measure CPU cost: `top` during AEC plus the wake-word recognizer on the 8×A53, at 48 kHz and at 16 kHz. If it does not fit, downsample the AEC to 16 kHz.
5. Acceptance per GOAL: music at 65 % volume, wake word from across the room, recognizer hit rate recorded over a series of trials.
6. Only then consider whether the AFE loopback can give a cleaner hardware reference than the software stream.

## 7. Risks

- Unlocked clocks make the filter slowly diverge; symptoms look like "AEC works for a minute then breaks".
- Adding latency to make AEC comfortable hurts the wake-word response and the perceived call quality.
- Software AEC on 8 A53 cores competes directly with the recognizer and the compositor — the whole system can end up too slow.
- There is no hardware mic mute on this unit (measured), so a muted-but-live stream is the normal state — AEC keeps running while nothing is audible to the user.

## 8. Open questions

- Do MI2S playback and DMIC capture share an AFE root clock on mainline, or not? Decisive.
- What round-trip latency and jitter does the real path have?
- Is the AFE loopback usable as a continuous reference, or only as a debug path?
- Can any Fluence module run under a mainline ADSP at all, or is it tied to the Android audio HAL?

## 9. Sources

- `evidence/stock-aec-props-20261030.txt` (properties, `afe_loopback` node).
- `../firmware-remoteproc/` (Fluence module presence); `../../JHB_REPORT.md` (prior design intent).
- Mainline DTS audio routing; `echo-cancellation/BRIEF.md`; `../microphones/ANALYSIS.md`, `../speaker/ANALYSIS.md`.
