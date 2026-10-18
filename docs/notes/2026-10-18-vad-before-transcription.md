# Voice activity detection before transcription (issue #8)

Question: does running Silero VAD on the recording before whisper help Koe's
accuracy or latency, and does it stop whisper from inventing text on silence,
without cutting off the start of words?

Method: `eval/vad_bench.py` (one command, `nice -n 15`, at most 4 inference
threads, one whisper-server). Public data only: the 200 fixed JSUT v1.1 clips
of `eval/public_bench.py`, plus synthetic variants built from them in memory.
No transcript is stored or printed. Model: large-v3-turbo (Metal), Koe base
prompt, no pack. Apple M1 Max, macOS 26.2, whisper.cpp
`0c7be696371069e0baa2515ed7aa08d5a5473aa6`, onnxruntime 1.21.0, seed 8.
Total runtime 969 s (about 16 minutes) with a warm cache.

## What was compared

Gates (what reaches whisper):

| Gate | Before whisper | After whisper |
|---|---|---|
| raw | whole clip | nothing (whisper's output as is) |
| koe | today's Koe: 30 ms RMS > 330 marks voice, padded 0.25 s before / 0.3 s after; no voice → not sent (`no_voice`) | today's Koe: hallucination list (retry without prompt, then drop), repetition / stock phrase (one retry with the whole window and temperature fallback, stock phrases removed) |
| vad | Silero VAD v5 (ONNX, Python, 1 thread), speech span padded 0.25 s / 0.3 s; no speech → not sent | same as koe |
| vad-tight | Silero VAD, padded 0.1 s / 0.1 s (word-cutoff probe) | same as koe |
| koe+server-vad | today's energy trim, then whisper-server's built-in Silero VAD (`vad=true`, segments padded 250 ms, gaps between segments removed); no speech → empty answer | same as koe |

Audio:

| Audio | Clips | Construction |
|---|---:|---|
| clean | 200 | JSUT clips as cached (each already has about 0.3 s of silence at both ends) |
| padded | 200 | 1.5 s before + 2.5 s after, white noise floor −60 dBFS (RMS ≈ 33, below Koe's threshold) |
| noisy | 200 | same padding, white noise floor −38 dBFS (RMS ≈ 412, above Koe's threshold; speech SNR ≈ 18 dB) |
| silence | 60 | white noise only, 1–6 s, 20 each at −60 / −45 / −38 dBFS |

Columns: CER (dropped or skipped clip = empty hypothesis), median / p95 of
gate + whisper time per clip (retries included), median gate time, total
seconds uploaded, clips skipped before whisper, dropped after, clips with a
non-empty result (on silence: hallucinations that would be pasted), and clips
whose first / last two normalized characters differ from the reference (word
cutoff indicator; the raw row is the floor set by recognition errors).

## Numbers

| Audio | Gate | Clips | CER (%) | Median (s) | p95 (s) | Gate (ms) | Sent audio (s) | Skipped | Dropped | Pasted | Head | Tail |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| clean | raw | 200 | 6.83 | 0.302 | 0.359 | 0.0 | 781.3 | 0 | 0 | 200 | 31 | 7 |
| clean | koe | 200 | 6.99 | 0.321 | 0.390 | 0.2 | 768.7 | 0 | 0 | 200 | 33 | 8 |
| clean | vad | 200 | 6.99 | 0.339 | 0.411 | 22.8 | 756.6 | 0 | 0 | 200 | 32 | 7 |
| clean | vad-tight | 200 | 7.70 | 0.313 | 0.386 | 16.6 | 707.9 | 0 | 0 | 200 | 32 | 6 |
| clean | koe+server-vad | 200 | 6.99 | 0.305 | 0.404 | 0.1 | 768.7 | 0 | 0 | 200 | 33 | 7 |
| padded | raw | 200 | 7.41 | 0.312 | 0.392 | 0.0 | 1581.3 | 0 | 0 | 200 | 34 | 8 |
| padded | koe | 200 | 7.04 | 0.287 | 0.332 | 0.4 | 790.0 | 0 | 0 | 200 | 33 | 7 |
| padded | vad | 200 | 7.06 | 0.307 | 0.353 | 28.0 | 777.0 | 0 | 0 | 200 | 31 | 6 |
| padded | vad-tight | 200 | 6.90 | 0.339 | 0.400 | 39.1 | 707.0 | 0 | 0 | 200 | 32 | 5 |
| padded | koe+server-vad | 200 | 7.04 | 0.300 | 0.356 | 0.3 | 790.0 | 0 | 0 | 200 | 32 | 6 |
| noisy | raw | 200 | 8.03 | 0.291 | 0.339 | 0.0 | 1581.3 | 0 | 0 | 200 | 38 | 12 |
| noisy | koe | 200 | 8.03 | 0.284 | 0.356 | 0.1 | 1581.3 | 0 | 0 | 200 | 38 | 12 |
| noisy | vad | 200 | 7.66 | 0.303 | 0.383 | 26.4 | 794.6 | 0 | 0 | 200 | 41 | 7 |
| noisy | vad-tight | 200 | 7.64 | 0.307 | 0.352 | 29.5 | 724.6 | 0 | 0 | 200 | 36 | 8 |
| noisy | koe+server-vad | 200 | 7.89 | 0.309 | 0.358 | 0.1 | 1581.3 | 0 | 0 | 200 | 39 | 7 |
| silence | raw | 60 | - | 0.250 | 0.290 | 0.0 | 211.2 | 0 | 0 | 60 | - | - |
| silence | koe | 60 | - | 0.000 | 0.292 | 0.1 | 76.3 | 40 | 2 | 18 | - | - |
| silence | vad | 60 | - | 0.011 | 0.019 | 11.3 | 0.0 | 60 | 0 | 0 | - | - |
| silence | vad-tight | 60 | - | 0.011 | 0.018 | 10.9 | 0.0 | 60 | 0 | 0 | - | - |
| silence | koe+server-vad | 60 | - | 0.000 | 0.034 | 0.1 | 76.3 | 40 | 20 | 0 | - | - |

```text
server_sha256=c174b19a2d4481b6245327c04f59599967938074a9712d89a5c17b3e0aaea533
turbo_sha256=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
vad_sha256=1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3
ggml_vad_sha256=29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf
```

A first full run of the four Python-side gates (before the server-side gate
was added) gave the same CER and count columns; medians differed by up to
0.03 s between the two runs (for example clean/raw 0.325 vs 0.302 s). Latency
differences of that size between gates are therefore run-to-run noise.

## Reading

- **Accuracy on speech: no gain in quiet conditions.** With a quiet floor
  (clean, padded) Koe's energy trim already finds the same edges as Silero:
  CER 6.99 vs 6.99 and 7.04 vs 7.06 / 7.04. Both are 0.16 points above raw on
  clean, which is the cost of the padding/window change on this sample, not of
  the detector.
- **Accuracy under a loud noise floor: small gain.** At −38 dBFS the energy
  trim marks the whole clip as voice (1581 s uploaded, identical to raw) and CER
  is 8.03. Silero still finds the speech: 7.66 (ends trimmed) and 7.89 (server
  side, gaps removed). That is 0.14–0.37 points on 200 clips.
- **Hallucinations on noise-only input: the real effect.** whisper returns
  text for all 60 noise clips. Today's Koe catches the 40 quiet ones with the
  energy gate and only 2 of the 20 loud ones with the hallucination list; 18
  would be pasted. Both VAD paths paste 0 of 60. Server-side VAD answers in at
  most 34 ms for these.
- **Word cutoff: none at 250 ms padding, visible at 100 ms.** The head
  mismatch count is 31–34 for raw, koe, vad and koe+server-vad on clean and
  padded audio; tail mismatches are 5–8. The tight 0.1 s padding keeps head
  counts similar but raises CER on clean audio from 6.99 to 7.70, so cutting
  closer than Koe's current padding loses content. The 250 ms padding should
  not be reduced.
- **Latency: within noise.** The Python ONNX gate costs 11–28 ms per clip on
  one thread; the server-side pass is inside whisper's time and the medians
  (0.305 / 0.300 / 0.309 s) sit within the 0.03 s run-to-run spread. Removing
  gaps between speech segments did not shorten whisper's time on these short
  clips, because `audio_ctx` is already sized to the utterance.

## Recommendation

Ship Silero VAD **as an opt-in, off by default**, through whisper-server's
built-in VAD rather than a new runtime in the app: the model is 0.9 MB, there
is no new dependency, and the request flag can be added per utterance. Keep
Koe's energy trim and the checks after transcription in front of and behind it;
keep 250 ms padding. The measured benefit is confined to loud noise floors
(fans, air conditioning, open offices): no pasted hallucinations on noise-only
input and a slightly lower CER. In quiet rooms it changes nothing, which is why
it stays off by default. Not evaluated: conversational speech, other speakers
and real room noise (white noise is a stand-in), and the Windows app.

Implemented in `macos/Sources/Koe/VAD.swift`:
`defaults write io.github.chaspy.koe vad -bool true`. Follow-up worth doing
before turning it on by default: count how often recorded `noise_db` in local
history is above −40 dB (numbers only), which says how often the loud-floor
case occurs for real users.
