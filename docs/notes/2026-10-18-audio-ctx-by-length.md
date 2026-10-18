# Encoder window (audio_ctx) by utterance length (issue #165)

A 19.7 s utterance came out garbled with Koe's automatic `audio_ctx` (1092) and
correct with the whole window. This note measures the automatic window against
the whole window by utterance length on public data.

## Method

- `eval/audio_ctx_bench.py` (needs the cached clips of `eval/public_bench.py`).
- Data: the 200 fixed JSUT v1.1 BASIC5000 clips. Each clip is trimmed of edge
  silence like Koe's energy trim. Single clips form the `<5 s` bucket. Longer
  utterances join consecutive clips with a 0.3 s pause, 30 per bucket, because
  JSUT clips are short. The reference is the joined transcripts.
- Model and request: large-v3-turbo on Metal, the bundled whisper-server, the
  Koe prompt (base prompt + `developer` pack), temperature 0, pack autocorrect.
  Each utterance is sent twice: with the old automatic window (Koe's formula:
  seconds × 55 + 64, between 768 and 1500, whole at 30 s) and with `audio_ctx=0`.
- "Garbled" means an utterance with CER above 50 %. "Foreign script" means a
  letter outside kana, kanji and Latin. "Invalid UTF-8" means the response could
  not be decoded; Koe read such a response as empty and dropped it.
- Only aggregate numbers are recorded. No transcript is stored.
- Run on 2026-10-18 on an Apple silicon Mac at `nice 15`, 498 s.

## Result

| Length | Utterances | auto ctx | CER auto (%) | CER full (%) | Garbled auto / full | Foreign script auto / full | Invalid UTF-8 auto / full | Median auto (s) | Median full (s) |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| <5 s | 188 | 768-768 | 7.03 | 6.74 | 0 / 0 | 0 / 0 | 0 / 0 | 0.291 | 0.540 |
| 5-7.5 s | 30 | 768-768 | 8.66 | 8.23 | 0 / 0 | 0 / 0 | 0 / 0 | 0.346 | 0.596 |
| 7.5-10 s | 30 | 768-768 | 12.04 | 6.46 | 1 / 0 | 0 / 0 | 0 / 0 | 0.363 | 0.614 |
| 10-12.8 s | 30 | 768-768 | 10.22 | 6.83 | 1 / 0 | 0 / 0 | 0 / 0 | 0.405 | 0.662 |
| 12.8-16 s | 30 | 772-943 | 54.91 | 6.23 | 16 / 0 | 5 / 0 | 4 / 0 | 0.673 | 0.699 |
| 16-20 s | 30 | 948-1120 | 26.49 | 7.79 | 2 / 0 | 0 / 0 | 0 / 0 | 0.628 | 0.741 |
| 20-24 s | 30 | 1171-1338 | 11.12 | 10.08 | 0 / 1 | 0 / 0 | 0 / 0 | 0.747 | 0.826 |
| 24-28 s | 30 | 1392-1500 | 6.81 | 6.61 | 0 / 0 | 0 / 0 | 0 / 0 | 0.892 | 0.910 |

Reproduce:

```sh
python3 eval/public_bench.py        # once, to cache the 200 clips
python3 eval/audio_ctx_bench.py
```

## Reading

- The shrunk window raises CER in every bucket. From 7.5 s to 20 s it breaks
  utterances outright: at 12.8–16 s the CER is 55 % against 6 %, and 16 of 30
  utterances are unusable. This matches the report in #165 (about 19 s, window 1092).
- The failure is not caught by the repetition check. Only part of it shows
  foreign script or invalid UTF-8, so detection alone cannot fix it.
- The whole window costs about 0.25 s of median latency below 10 s and less
  above (0.02–0.1 s from 16 s). Below 5 s the CER difference is 0.3 points with
  no garbled utterance.

## Decision

- On macOS, `audioCtx=auto` (the default) now uses the whole window for every
  length (`AudioWindow.shrinkBelowSeconds = 0`). This is the only setting that
  meets "no bucket worse than the whole window".
- If short-utterance latency matters more, `shrinkBelowSeconds = 7.5` keeps the
  shrunk window below 7.5 s. That saves about 0.25 s there for 0.3–0.4 CER
  points and no garbled utterance in this run.
- As a safety net for a fixed `audioCtx`, a response from a shrunk window that
  contains foreign script or invalid UTF-8 is transcribed once more with the
  whole window (`retried_full_window` in the history record).
- Windows uses the same formula with the small model on the CPU. It is not
  measured here and is unchanged.
