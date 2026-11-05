# tts-distil: Japanese and Mandarin quality, and a public release

## Goal

Straylight speaks English, Japanese and Mandarin in one persona, in real time,
on the tablet's CPU. The English student is close to its teacher (Kokoro-82M
v1.0); Japanese and Mandarin are further behind. Close that gap as far as the
teacher allows, raise the teacher's own ceiling where a clean way exists, and
publish the three voices on Hugging Face with an honest model card.

## Done means

- **Japanese and Mandarin are as close to their teacher as English is**: within
  about 0.1 UTMOS of the teacher (or an equivalent gap on a measure that is not
  English-biased), with recognition error no worse than the teacher's, on the
  held-out lines in `cases/eval-lines.tsv`.
- **The Mandarin gap is measured, not assumed.** UTMOS is trained on English
  speech, so the Mandarin result is backed by a second measure and a blind A/B
  listening set (teacher against student) that the user has heard.
- **The front end is the best one available for each language.** Japanese is
  tested with UniDic (the dictionary misaki uses, and presumably Kokoro's
  training data) against Open JTalk's NAIST dictionary, rendered by the
  teacher; the better one ships. The front end's own fixes stay whichever
  dictionary wins: punctuation kept, counters read properly (3日 みっか,
  4時 よじ, 15分 じゅうごふん) and clock times read as times.
- **A better Mandarin teacher is evaluated.** `Kokoro-82M-v1.1-zh` is checked
  for licence and training-data terms, tone sandhi, its voices and whether the
  persona's blend carries over; it replaces v1.0 as the Mandarin teacher if it
  is clearly better and clean.
- **Still real time on the tablet**: speech-path RTF at or under 0.60 in every
  language, decoder no wider than `x25k2`, memory as today.
- **Installed**: the new voices run in the live service, and the image build
  stages them (listener built with `--features asr,tts`, the voice
  directories, `.ort` files only, `SHA256SUMS` repinned).
- **Published**: one Hugging Face repository holding the three voices (ONNX
  fp32 and MatMul uint8, `.ort`, voice vectors), with a model card that
  states:
  - the numbers above and the tablet speed table;
  - that each model is one voice (or blend), not a multi-speaker decoder;
  - how it behaves on phonemes from Python misaki as well as from our front
    end, measured;
  - the licence chain and the Apache-2.0 notices for Kokoro and Paradee;
  - a minimal ONNX Runtime example.

  The account or organisation, and which voices go out, are the user's
  decision; the card is shown to the user before anything is uploaded.

## Limits

- **Pitch accent in Japanese** is the teacher's limit: Kokoro v1.0's Japanese
  phonemes carry no accent marks. Fixing it means retraining the text side and
  is not part of this goal; the card says so.
- Retrains are fine whenever they buy quality. Wall-clock time matters more
  than RunPod cost.

## Rules

- **Licence chain stays clean**: CC0 and public-domain text only, Apache-2.0
  teachers, no third-party recordings, no weights trained on anything else
  (Paradee's released weights stay unused). Every new dependency's licence is
  recorded in `NOTES.md`.
- RunPod as in `NOTES.md`: the key stays on stadia-testbed, pods and volumes
  are deleted when a run ends, and spend is recorded.
- Big files on the Shared partition, not `/tmp` or the NAS.
- Device rules from `WORKSTREAMS.md`; installing on the tablet is the
  integrator's step.

## Current state (2026-11-04)

| | UTMOS (teacher) | WER / CER (teacher) | tablet RTF |
| --- | --- | --- | --- |
| en `af_heart` | 4.40 (4.51) | WER 0.8 % (1.6) | 0.60 |
| ja `jf_alpha*0.7+af_heart*0.3` | 4.22 (4.39) | CER 8.0 % (8.4) | 0.55 |
| zh `zf_xiaoni*0.7+af_heart*0.3` | 3.81 (4.23) | CER 1.4 % (2.9) | 0.55 |

The Japanese second stage stopped at 20,000 of 30,000 steps while still
improving.

## Next

1. UniDic against NAIST through the teacher; Japanese student on the winner,
   to the full 30,000 steps.
2. Mandarin: a second measure and the blind listening set; `v1.1-zh` as
   teacher; retrain if it wins.
3. Students on misaki's phonemes, for the card.
4. The Mandarin first-piece rule in the listener's text splitter (first audio
   is 1.2-2.9 s today).
5. Install, stage in the image, and prepare the Hugging Face repository and
   card for the user's review.
