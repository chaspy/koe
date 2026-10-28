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

Override these with `--server`, `--turbo-model`, `--cache`, and `--packs` (default `developer`, the pack Koe enables by default). The script lowers
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
| turbo-packs | same | base prompt + the `developer` pack (`--packs`), pack autocorrect | same |
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

## VAD before transcription (`vad_bench.py`)

```sh
nice -n 15 python3 eval/vad_bench.py
```

Compares what reaches whisper under four gates, on the same 200 JSUT clips
plus synthetic variants built in memory from them, with the turbo model and the
Koe base prompt (no pack). Requires `onnxruntime` and `numpy` in addition to the
dependencies above; it shares the cache, the lock file and the thread/priority
limits with `public_bench.py`. `--limit N` runs the first N clips for a smoke
test; `--seed` changes the noise generator (default 8).

The command downloads the **Silero VAD** v5 ONNX model (MIT, 2.3 MB) and its
LICENSE from [snakers4/silero-vad](https://github.com/snakers4/silero-vad) at
commit `1e261b036686cd0017d500ee96acd1c4ba572a9d`, verifying SHA-256
`1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3` for the
model, into the external cache. The VAD runs on one CPU thread with Silero's
default thresholds (speech at 0.5, off below 0.35 for 100 ms, speech shorter
than 250 ms ignored) and is reset for every clip.

| Gate | What is sent to whisper | After transcription |
|---|---|---|
| raw | the whole clip | nothing (pure whisper output) |
| koe | Koe's energy trim: first/last 30 ms window with RMS above 330, padded 0.25 s before and 0.3 s after; no loud window → `no_voice`, whisper not called | Koe's checks: fixed hallucination list (retry without prompt when ≥ 1 s of audio, then drop), repetition or stock phrase (one retry with the whole window and temperature fallback, then stock phrases removed) |
| vad | Silero speech span with the same 0.25 s / 0.3 s padding; no speech → whisper not called | same as koe |
| vad-tight | Silero speech span padded 0.1 s / 0.1 s (word-cutoff probe) | same as koe |
| koe+server-vad | Koe's energy trim, then whisper-server's built-in Silero pass (`vad=true`, `vad_speech_pad_ms=250`; speech segments concatenated, nothing transcribed without speech). This is the path the macOS opt-in (`VAD.swift`) uses | same as koe |

For the server-side gate the command also downloads `ggml-silero-v5.1.2.bin`
(the same weights converted for whisper.cpp, MIT, 0.9 MB) from
[ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad), revision
`9ffd54a1e1ee413ddf265af9913beaf518d1639b`, SHA-256
`29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf`, and starts
whisper-server with `-vm`. `--conditions` selects a subset of gates.

| Audio | Clips | Construction |
|---|---:|---|
| clean | 200 | the public clips as cached |
| padded | 200 | 1.5 s before, 2.5 s after, white noise floor at −60 dBFS (RMS ≈ 33, below Koe's threshold) over the whole clip |
| noisy | 200 | same padding, white noise floor at −38 dBFS (RMS ≈ 412, above Koe's threshold, speech SNR ≈ 18 dB) |
| silence | 60 | white noise only, 1–6 s, 20 clips each at −60, −45 and −38 dBFS |

Columns: **CER** as above (a dropped or skipped clip counts as an empty
hypothesis); **Median / p95** of gate time plus whisper time per clip (retries
included, skipped clips contribute the gate time only); **Gate (ms)** median
time of the trim/VAD step; **Sent audio** total seconds uploaded; **Skipped**
clips never sent to whisper; **Dropped** clips rejected after transcription;
**Pasted** clips with a non-empty result (on silence, this is the hallucination
count that would reach the user); **Head / Tail** clips whose first / last two
normalized characters differ from the reference (a word-cutoff indicator; the
raw row is the floor caused by recognition errors alone). The repetition
collapse of the app is not reproduced; outputs are only retried and stock
phrases removed. White noise is a stand-in for room noise, not a recording of
one. Results and the recommendation are in
`docs/notes/2026-10-18-vad-before-transcription.md`. On 2026-10-18 (same machine
as above, warm cache) the full command took **969 seconds (about 16 minutes)**
for 4,200 scored requests.

## Japanese ASR engines on the Mac (`asr_bench.py`, #180)

`python3 eval/asr_bench.py` runs every engine, one at a time, on the same data. `--engines <name> …` runs some of them. Run `public_bench.py` once first, so that the JSUT clips are cached. Results and the recommendation are in `docs/notes/2026-10-19-asr-engines-on-mac.md`.

- **Data**: public or synthetic only, never a real person's voice.
  - The JSUT clips of `public_bench.py`, in the length buckets of `audio_ctx_bench.py`: 60 single clips under 5 s, and 20 joined utterances per bucket up to 28 s.
  - 60 sentences with terms from `packs/developer.txt`, spoken by the macOS voice Kyoko (`say`) into the cache.
- **Engines**:
  - `whisper-turbo-metal`: Koe's default, large-v3-turbo on Metal
  - `whisper-turbo-coreml`: the same model with whisper.cpp's prebuilt Core ML encoder. Its whisper-server is built once from the source revision Koe uses (0c7be69) into the cache.
  - `kotoba-whisper-v2-metal`: kotoba-whisper v2.0 ggml
  - `apple-speechanalyzer`: macOS 26 SpeechTranscriber ja_JP, through `speechanalyzer_cli.swift`
  - `apple-dictation`: the same helper with DictationTranscriber (preset `shortDictation`)
  - `parakeet-ja-sherpa-cpu`: Parakeet-ja through sherpa-onnx 1.13.8, through `sherpa_cli.py`, in a venv in the cache built from `asr_requirements.txt` with `--require-hashes`
- **Downloads**: every model is pinned by revision and SHA-256, into the cache (`~/Library/Caches/koe-public-bench/asr-models`).
- **More sherpa-onnx engines** (2026-10-24): `moonshine-tiny-ja-sherpa-cpu`, `qwen3-asr-0.6b-sherpa-cpu` (hotwords: the `hints` condition), `reazonspeech-zipformer-sherpa-cpu`, and `parakeet-ja-sherpa-coreml` (ONNX Runtime's Core ML provider), all through `sherpa_cli.py <kind> <model dir> 4 <provider>`. Moonshine's Japanese model is under a non-commercial licence; it is only measured here.
- **Noise** (`--noise OOFFICE` or `PCAFETER`, `--snr 20 15 10`): Koe's default condition only (pack, and hints for engines that take them) on the same utterances and term sentences with DEMAND noise mixed in, as `voice_isolation_bench.py` does (its SHA-256-pinned cache). Saved as `<engine>@noise`, next to the clean results.
- **WhisperKit** (`whisperkit-turbo`, `whisperkit-turbo-626mb`): WhisperKit 1.1.1 through `whisperkit_cli/` (SwiftPM, built into the cache; versions pinned in `Package.swift` / `Package.resolved`), with the large-v3 turbo Core ML models of `argmaxinc/whisperkit-coreml`, pinned file by file (SHA-256 and revision) in `whisperkit_models.json`. The first load compiles the Core ML model (a few minutes).
- **Conditions**:
  - `none`: no prompt
  - `base`: Koe's base prompt
  - `pack`: the developer pack in the prompt, with pack autocorrect, as Koe runs by default

  - `hints`: every pack term as a vocabulary hint (`AnalysisContext.contextualStrings`), with pack autocorrect

  Engines without a prompt get `none` and `pack` (autocorrect only); the SpeechAnalyzer engines also get `hints`.
- **Metrics**:
  - CER before (spaces removed) and after (NFKC, punctuation removed) normalisation, overall and per bucket, with the count of empty answers
  - median and p90 seconds per bucket
  - terms right
  - peak RSS of the engine process
  - model size and licence
- **Limits**: `nice 15` and 4 threads. The run stops when free plus inactive memory drops below 6 GB (`--min-available-gb`). Only numbers are printed and stored (`asr-results.json` in the cache); no transcript is kept.

### 聞き間違い率と反復ペア

`koe_eval.py daily` は、履歴の `asr_error` と従来の `communication` から
「聞き間違い」「伝わらなかった」を日別に表示します。対象期間は既存の `--days` と同じ
録音日時基準、分母は understood + corrected（unclear は別欄）です。
`asr_error` のない旧履歴が判定済み件数に混在する日は、聞き間違い率を `-` とし推測しません。
`improve_judged` の judged はループで保存できた判定件数（unclear を含む）です。

標準出力は数値集計だけです。`reports/daily-YYYY-MM-DD.md` のローカル報告だけに、
7日間で同じ wrong/right が3発話以上のペアを表示します。既存の候補採用条件を通ったペアを
発話履歴の `mishearings` に記録するため、候補ファイルの累積回数を7日間の回数と誤認しません。
履歴に保存した `prompt_terms` に正しい語が毎回あれば「エンジン限界」、一度でも無ければ
「辞書・用語選択」、欠損だけで有無が確定しなければ「分類保留」です。
別名の登録は提案だけで、このレポートは辞書を変更しません。

新しい履歴フィールドは `asr_error`（回答に error があるときだけ）、`read_ok`（bool/null）、
`impact`（misacted/redo/dropped/null）、`unknown`、`judged_at`、`prompt_terms`、`mishearings`。
従来の communication / communication_impact は維持します。新しい語の記録は履歴内だけで、
既存の履歴保持期間が適用されます。日次報告は既存と同じローカル reports 内に保存します。
Windows への対応は別途です。

## Voice isolation and whisper (`voice_isolation_bench.py`, #197)

Measures whether Apple's voice isolation helps or hurts whisper, on public data only.
Results and limits: `docs/notes/2026-10-24-voice-isolation-whisper.md`.

- **Speech**: the first 100 JSUT clips of `public_bench.py` (run it once first; this script reads the cache and downloads no speech), and the 60 term sentences of `asr_bench.py` spoken by the macOS voice (cached by sentence under `~/Library/Caches/koe-eval/voice-isolation/asr-terms`).
- **Noise**: **DEMAND** (Thiemann, Ito, Vincent 2013, [CC BY 4.0](https://zenodo.org/records/1227121)), channel 1 of `OOFFICE` (office; `--noise OOFFICE PCAFETER` adds the cafeteria). Downloaded once by a SHA-256-checked script into `~/Library/Caches/koe-eval/voice-isolation/demand`; nothing is committed. Each clip gets a fixed piece of the noise (offset from the clip's key) mixed at 20, 15 and 10 dB SNR (whole-clip RMS), plus the clean clip.
- **Processing**: `AUSoundIsolation` (Apple's voice-isolation effect unit, wet/dry 100 %, "sound to isolate" 1.0 = its defaults), applied **offline** by `sound_isolation_cli.swift` with AVAudioEngine manual rendering at 48 kHz, then back to 16 kHz PCM16 as Koe captures. No microphone or speaker is used. `AUVoiceProcessor` (the voice-processing I/O unit behind `setVoiceProcessingEnabled`) is tied to a live input and output device and cannot render files, so it is not measured.
- **Whisper**: the turbo model of `asr_bench.py` (pinned revision and SHA-256), on its own whisper-server on a free port, with the developer pack prompt and Koe's autocorrect (what Koe sends by default).
- **Metrics**: CER after `public_bench.normalize`, terms right (`asr_bench.fold` containment), and how many utterances have a run of exact zeros of 100 ms or more inside the voiced span (as Koe's `SelfDiagnosis.ZeroRuns`). For each condition, the paired difference on − off of the CER with a 95 % bootstrap interval (2,000 resamples, fixed seed). Only these numbers are printed and saved (`results.json` in the cache).

```sh
python3 eval/voice_isolation_bench.py
python3 -m unittest eval/test_voice_isolation_bench.py
```

## Release → paste latency on any Mac (`paste_bench.py`)

Times the whisper request Koe makes after the key is released, with the same
synthesized audio (`say`, Japanese voice Kyoko when present; `audio_sha` shows
whether two Macs used identical audio) at 3, 8, 15 and 25 s. Standard library
only, so it runs on another Mac with Koe installed by copying this one file:

```sh
nice -n 15 python3 paste_bench.py              # borrow the running Koe's whisper-server
nice -n 15 python3 paste_bench.py --own        # own server; takes ~/.config/madoguchi/locks/whisper
nice -n 15 python3 paste_bench.py --stress 8   # also with 8 busy CPU processes
```

On a Mac without this checkout (for example a work MacBook), one line with an
authenticated `gh`; nothing is saved to disk:

```sh
gh api repos/chaspy/koe-dev/contents/eval/paste_bench.py -H 'Accept: application/vnd.github.raw' | nice -n 15 python3 - --stress 8
```

Copy the whole output back. It looks like this (Mac Studio M1 Max, Koe 0.9.5,
load1 about 700 at the time):

```
# Koe paste latency bench
model=Mac13,1 chip=Apple M1 Max cores=10 perf_cores=8 mem_gb=32 macos=26.2 koe=0.9.5
voice=Kyoko audio_sha=dfc4f16c765f reps=2 server=koe

## as is  load1 686.6-704.5
| audio (s) | whisper median (ms) | whisper p90 (ms) | total est. median (ms) |
|---:|---:|---:|---:|
| 3 | 617 | 714 | 962 |
| 8 | 624 | 639 | 969 |
| 15 | 733 | 746 | 1078 |
| 25 | 961 | 963 | 1306 |
```

Output is numbers only (machine model, chip, Koe version, load1, median / p90
per length); transcripts are discarded. `total est.` adds Koe's fixed stages:
the 0.25 s recorded after release and ~0.1 s for the paste.
