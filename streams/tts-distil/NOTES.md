# tts-distil: real-time voices distilled from Kokoro (in progress)

Goal: continuous speech on the tablet in Japanese (today Kokoro on the CPU, RTF about 3, so replies come in pieces) and a licence-clean Mandarin (today's fast Piper AISHELL-3 voice fails the commercial-use rule), optionally English too so one persona speaks all three. Method: Kokoro-82M (Apache-2.0) renders clean-licence text in the chosen voices (en `af_heart`, ja `jf_alpha*0.7+af_heart*0.3`, zh `zf_xiaoni*0.7+af_heart*0.3`) from the tablet's own phonemiser output; a small Matcha-TTS (MIT) student per language learns from it, with a Vocos vocoder trained on the same Kokoro audio, so the licence chain is clean end to end. Target on the tablet: RTF ≤ 0.5 on 6 threads (the LJSpeech Matcha + Vocos already measures 0.41-0.50, see `streams/tts/NOTES.md`).

**Status (2026-11-01): stopped part way.**

- Done: training image (`docker/Dockerfile`, NGC PyTorch on the GB10), corpus builder (`scripts/build-corpus.py`: Common Voice CC0 sentences, Aozora Bunko public-domain text, assistant-style lines from `scripts/assistant-lines.py`; about 12-16 h of audio per language), Kokoro renders for en, ja and zh (`scripts/kokoro-render.py`, on the PGX under `~/straylight-tts/data/kokoro-{en,ja,zh}`), Matcha data prep and config (`scripts/prep-data.py`, `scripts/matcha-config.sh`), Vocos training script (`scripts/train-vocos.py`).
- Running when the stream stopped: Vocos training on the PGX, container `vocos` (image `straylight-tts:1`, started 2026-11-01 02:14 UTC, 400 000 steps at about 5 it/s, so about 22 h; logs `~/straylight-tts/logs/`, checkpoints `~/straylight-tts/runs/vocos/`). Stop it with `docker stop vocos` if the GPU is needed.
- Failed and not yet fixed: the first Matcha English run (`runs/matcha-en/train.log`): Hydra cannot locate `matcha.data.text_mel_datamodule.TextMelDataModule`, so the Matcha package is not importable inside the container as configured (check the install path in the image and `PYTHONPATH`).
- Not done: Matcha training for each language, evaluation (`scripts/eval.py`: ASR round trip, distance to Kokoro, brand line, Japanese pitch-accent pairs via `streams/tts/scripts/rt-accent.py`), ONNX export (`scripts/export-onnx.py`), device measurement and integration (straylight-voice branch `tts-distil`, worktree `/home/jethac/Projects/straylight-voice-distil`, which has uncommitted Matcha loader changes in `listen/src/tts/`).

## The PGX

`ssh -o HostName=thinkstationpgx-00b4 pgx` (tailnet; the `.local` name in the SSH config only resolves on the LAN). Shared machine: other GPU jobs run there, so `scripts/pgx-run.sh` starts one detached container with nice 10, 48 GB RAM, 6 CPUs and a GPU memory fraction, with `~/straylight-tts` mounted at `/w`. Never touch processes that are not ours.

## Licence chain (as designed)

Text: CC0 and public domain only (record each source). Teacher: Kokoro-82M and its voices, Apache-2.0. Student and vocoder: trained here from the teacher's audio, code MIT (Matcha-TTS) and MIT (Vocos). No third-party recordings.
