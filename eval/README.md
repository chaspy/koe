# Public Japanese speech benchmark

Run from the repository root on macOS with Python 3.9+, ffmpeg and a built
whisper.cpp server:

```sh
nice -n 15 python3 eval/public_bench.py
```

Defaults match the local Koe installation:

- Server: `~/.local/src/whisper.cpp/build-static/bin/whisper-server`
- Turbo: `~/Library/Application Support/Koe/models/ggml-large-v3-turbo.bin`
- Cache: `~/Library/Caches/koe-public-bench` (must be outside this checkout)

Override these with `--server`, `--turbo-model`, and `--cache`. The script lowers
its priority if needed, caps inference/BLAS threads at four, uses one server at a
time, and locks the cache against concurrent runs. ffmpeg uses one thread.
Avoid running another heavy job alongside it. The runner targets POSIX hosts;
the Windows profile is **not a measurement of a Windows machine**.

## Download and licenses

The command downloads **JSUT v1.1**, `basic5000/BASIC5000_0001` through
`BASIC5000_0200`, in ascending order (200 clips, no random selection). It reads
only selected ZIP members using HTTP Range, checking the official archive's
fixed size and ETag plus ZIP member CRCs. A changed archive fails closed.
The first 200 IDs are a convenience sample, not a representative or held-out
ASR test set. No claim is made about model training overlap.

**Before downloading JSUT, read the [official terms](https://sites.google.com/site/shinnosuketakamichi/publication/jsut).**
Audio is permitted for academic research, non-commercial research (including
within companies), and personal use. Commercial use requires contacting the
rights holders; general redistribution is not permitted. The basic5000 text
combines Wikipedia (CC-BY-SA 3.0), the Tanaka Corpus (CC-BY 2.0), and original sentences (CC-BY-SA 4.0), as detailed in
the archive. The command retains those license files beside the cached subset. It converts audio to mono 16 kHz PCM16 WAV and
keeps only the selected references. Do not commit or redistribute this cache.
Citation: Ryosuke Sonobe, Shinnosuke Takamichi, Hiroshi Saruwatari,
“JSUT corpus: free large-scale Japanese speech corpus for end-to-end speech
synthesis,” arXiv:1711.00354, 2017.

The command also downloads `ggml-small-q5_1.bin` (MIT-licensed Whisper weights)
from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp), revision
`5359861c739e955e79d9a303bcbc70fb988958b1`, verifying SHA-256
`ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb`.
The existing turbo model is not downloaded or modified. Model and server
SHA-256 identifiers are printed so results can be tied to exact binaries.
Network use is limited to these explicit public benchmark downloads and the
loopback inference server; nothing is uploaded to a remote service.

Common Voice and other speakers/domains are not included in this initial
benchmark. JSUT is clean read speech from one female speaker, so results do not
establish conversational, microphone, or developer-vocabulary accuracy.

## Conditions and metrics

| Condition | Model/backend | Prompt and correction | Decoding |
|---|---|---|---|
| turbo-base | large-v3-turbo, Metal when available | Koe base prompt, no pack | macOS server defaults, temperature 0 with default fallback |
| turbo-packs | same | base prompt + repository packs, pack autocorrect | same |
| small-cpu-packs | small-q5_1, CPU (`-ng`) | base prompt + repository packs, pack autocorrect | Windows CPU profile: beam 1, best-of 1, flash attention, temperature 0, fallback disabled |

All profiles use Japanese and four inference threads. `audio_ctx` follows Koe's
utterance-sized window (minimum 768 frames, `ceil(seconds * 55) + 64`, capped at
1500; 30 seconds or more uses the full window). Duration is the complete public
clip, without microphone/VAD trimming. Pack terms use repository file order
(sorted filenames), deduplication and Koe's 120-character budget, equivalent to
an empty personal history. No personal dictionary, history, previous utterance,
LLM cleanup, repetition retries or UI/paste path is accessed. Pack correction
uses the existing `koe_bench.py` helper. Thus this measures **first-pass ASR**,
not final app output or end-to-end interaction latency.

- **CER**: corpus-level sum of Levenshtein edits divided by total reference
  characters, after NFKC and removal of Unicode punctuation and whitespace.
  Case, kana/kanji and number spelling are not folded. CER can exceed 100%.
- **Median / p95**: loopback HTTP inference wall time, including upload and
  response, excluding file loading, startup, download, conversion, scoring and
  pack autocorrect. p95 uses nearest rank (`ceil(0.95 * n)`). One warm-up request
  per condition is excluded; every condition then scores all 200 clips.
- **Repetitive outputs**: raw outputs satisfying Koe's thresholds: a sentence
  of at least four characters occurs three times; a separator-delimited word
  occurs five consecutive times; or a non-numeric 2–6-character unit occurs six
  consecutive times. This is a heuristic count, not a labeled hallucination rate.

Only aggregate numbers and reproducibility identifiers are printed. Server
stdout/stderr are discarded; hypotheses are never saved, even to the cache.
Failures produce a sanitized exception class and exit nonzero, without a partial
results table. Downloads are atomic; successful converted clips are reused.

## Measured run and runtime

On 2026-10-18, Apple M1 Max / macOS 26.2 / ffmpeg 7.1.1, the full command
completed in **299.1 seconds (about 5 minutes)** including the initial subset
and small-model downloads, conversion, warm-ups and all 600 scored requests.
Network speed and machine load affect this duration. The fixed audio totals
781.267 seconds; the resulting cache is about 217 MiB. A warm-cache runtime
was not separately measured. whisper.cpp revision:
`0c7be696371069e0baa2515ed7aa08d5a5473aa6`. Processes inherited nice 20 in this
shell after invocation with `nice -n 15`; inference threads were capped at four.
Turbo used the default Metal backend; small used CPU only.

| Condition | Clips | CER (%) | Median (s) | p95 (s) | Repetitive outputs |
|---|---:|---:|---:|---:|---:|
| turbo-base | 200 | 6.83 | 0.310 | 0.375 | 0 |
| turbo-packs | 200 | 7.70 | 0.331 | 0.391 | 0 |
| small-cpu-packs | 200 | 18.07 | 0.450 | 0.515 | 1 |

The developer pack worsened CER on this sample; these general read sentences
do not establish its benefit for developer terminology. The small profile's
one repetition is counted before any app retry/collapse logic.

```text
elapsed_seconds=299.1
server_sha256=c174b19a2d4481b6245327c04f59599967938074a9712d89a5c17b3e0aaea533
turbo_sha256=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
small_sha256=ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb
```

## Validation

```sh
python3 -m unittest discover -s eval -p 'test_*.py'
```

Tests use synthetic text/audio and cover fixed IDs, CER weighting, Unicode
normalization, p95, repetition thresholds, pack behavior, audio windows, HTTP
profiles and archive range validation.
