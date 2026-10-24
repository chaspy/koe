# Voice isolation and whisper (#197, measurement only)

Does Apple's voice isolation help or hurt Koe's transcription? Measured on public
data, with the processing applied offline. No app change.

## Result

| Condition | Processing | CER | CER on − off (95 % interval) | Terms right | Utterances with zero runs ≥ 100 ms |
|---|---|---|---|---|---|
| clean | off | 9.0 % | | 25/60 | 0/160 |
| clean | on | 8.9 % | −0.2 pt (−1.6 to +0.9) | 23/60 | **60/160** |
| office noise, SNR 20 dB | off | 8.9 % | | 25/60 | 0/160 |
| office noise, SNR 20 dB | on | 8.8 % | −0.0 pt (−2.2 to +1.3) | 22/60 | 35/160 |
| office noise, SNR 15 dB | off | 8.6 % | | 24/60 | 0/160 |
| office noise, SNR 15 dB | on | 10.6 % | +2.1 pt (−0.4 to +6.2) | 22/60 | 38/160 |
| office noise, SNR 10 dB | off | 8.9 % | | 25/60 | 0/160 |
| office noise, SNR 10 dB | on | 11.1 % | +2.2 pt (−0.3 to +6.3) | 25/60 | 36/160 |

CER: 100 JSUT clips. Terms: 60 term sentences (synthetic voice). Zero runs: all 160.

- **It does not help.** In no condition is the CER lower with the processing on.
  whisper (turbo, with Koe's prompt) is already robust to this office noise: with
  the processing off, the CER stays at 8.6–9.0 % from clean to 10 dB.
- **In noise it tends to hurt.** At 15 and 10 dB the CER is about 2 points higher
  with the processing on. Both 95 % intervals reach just below 0, so the difference
  is not significant with 100 clips.
- **On clean audio the CER does not change**, but terms right drop slightly (25 → 23 of 60, within noise).
- **It produces runs of exact digital zero.** With the processing on, 60 of 160
  clean utterances have a zero run of 100 ms or more inside the speech; with it off,
  none do in any condition. This is the same signature as the user report in #197
  (zero runs appearing from a certain time in a quiet room). It supports, but does
  not prove, that Voice Isolation produced those zeros (see Limits).

**Conclusion for #197:** no opt-in setting. The processing does not improve
recognition in quiet or in noise here, and it leaves digital-zero runs that Koe's
self-diagnosis (#211) already flags. The existing hint wording ("『声を分離』なら
『標準』に戻して試して") is consistent with this result.

## Method

- **Speech**: JSUT v1.1 `BASIC5000_0001`–`0100` (the cache of `eval/public_bench.py`;
  official terms: non-commercial research use), 16 kHz mono. Terms: the 60 sentences
  of `eval/asr_bench.py` (developer-pack terms in fixed templates), spoken by the
  macOS voice Kyoko.
- **Noise**: DEMAND `OOFFICE` channel 1 (CC BY 4.0, Zenodo record 1227121), a fixed
  piece per clip, mixed at 20 / 15 / 10 dB SNR (whole-clip RMS), plus no noise.
- **Processing**: `AUSoundIsolation` (Apple's voice-isolation effect unit), at its
  defaults (wet/dry 100 %, sound to isolate 1.0), applied offline with AVAudioEngine
  manual rendering at 48 kHz, then converted to 16 kHz PCM16 as Koe captures
  (`eval/sound_isolation_cli.swift`). No microphone or speaker.
- **Recognition**: whisper.cpp `whisper-server` with `ggml-large-v3-turbo` (the pinned
  file of `eval/asr_bench.py`), started on its own free port, Koe's developer-pack
  prompt and autocorrect, temperature 0, Koe's audio_ctx rule.
- **Metrics**: CER after NFKC and removing spaces and punctuation; a term is right
  when its folded form is in the folded output; zero runs as Koe's `SelfDiagnosis`.
  The interval is a paired bootstrap over the 100 clips (2,000 resamples, fixed seed).
- Run: `python3 eval/voice_isolation_bench.py` (about 17 minutes on an Apple Silicon
  Mac with 32 GB, run at `nice -n 15`; one whisper request at a time). Only the
  aggregate numbers above are kept.

## Limits

- **AUSoundIsolation is not proven to be the same processing as the macOS microphone
  mode 「声を分離」 (Voice Isolation).** The system mode runs inside the capture path
  and cannot be switched on for a file; the effect unit is the voice-isolation DSP
  that Apple exposes for offline use. Their settings or versions may differ.
- **`setVoiceProcessingEnabled` (AUVoiceProcessor: echo cancellation, gain control)
  is not measured.** It is an I/O unit tied to a live input and output device and
  cannot render a file; measuring it would need playing through a speaker into the
  microphone, which this study does not do.
- One speaker (JSUT is one female voice reading), read speech, one noise type
  (office). Terms are spoken by a synthetic voice. Babble noise (`--noise PCAFETER`)
  and other speakers (Common Voice) are not measured.
- 100 clips: differences of about 2 points are not significant. A larger run could
  confirm the noisy-condition trend.
- Mixing is digital (no room acoustics or microphone), so it is not the same as a
  real microphone in a real room.
