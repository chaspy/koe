# Changelog

Versions follow the rule in [CONTRIBUTING.md](CONTRIBUTING.md#versioning). Each release's notes on GitHub are taken from its section here.

## Unreleased

## 0.4.2 — 2026-10-16

### macOS
- Fixed: when whisper-server had stopped (for example killed from outside), every utterance failed with "Could not connect to the server" until Koe was restarted. Koe now checks the server when the key is pressed and restarts it while you speak, retries a transcription once after restarting the server if the connection fails, and checks every minute while idle. Recording is allowed while the server is restarting; the transcription waits for it. A second server is not launched while one is still loading.

### Windows
- No changes.

## 0.4.1 — 2026-10-16

### Windows
- Fixed: the first utterance after about 10 minutes without speaking waited about a second before transcription started (seen on a tester PC: 1.12 s between record_stop and whisper-server starting, 0.02 s the next time). Koe recounted how often each term was used — reading up to 600 history files — right before transcribing. The counts are now refreshed in the background (at start and after a paste when older than 5 minutes) and the transcription only reads the cached counts, as on macOS (#89). The startup no longer waits for it either. koe.log shows each preparation step (`prepare_ms total= trim= wav= glossary= packs= usage= prompt= usage_age=`) and `usage_counted ms=`.

### macOS
- No changes.

## 0.4.0 — 2026-10-16

### Repository
- Removed the original `whisper-ja-toggle` CLI (the shell script, its Makefile and README section). Koe.app replaces it; it is still in the git history of earlier releases.

### Windows
- GPU support (Vulkan): Koe ships `whisper-server-vulkan.exe` (whisper.cpp v1.9.2 built with `-DGGML_VULKAN=ON` by the new whisper-vulkan workflow) next to the CPU build. With `"gpu": "auto"` (default) Koe starts the Vulkan build and keeps it only if it runs on a GPU *and* is faster: on first start it transcribes a short bundled test clip (`assets\probe.wav`, synthetic speech) once on the GPU and once on the CPU and uses the faster one, because small integrated GPUs can be slower than the CPU. The result is saved in `%LOCALAPPDATA%\Koe\backend.json` and reused until the version, the model or the display adapters change. If the Vulkan build fails to start, finds no GPU device (`ggml_vulkan: No devices found` / `no GPU found`), or fails its first transcription, Koe switches to the CPU build. Menu → 「GPU を使う」 turns it on / off (`"gpu": "off"`).
- On a GPU, speed first does not shrink the window (whole window for accuracy; `gpuAudioCtx`, default 0).
- koe.log shows `server_backend=gpu|cpu`, `backend_measure gpu_ms= cpu_ms= choice=`, `gpu_fallback reason=` and the display adapters; diagnostics add the GPU settings, the measurement and `whisper-server-vulkan.log`.

### macOS
- No changes.

## 0.3.5 — 2026-10-16

### Windows
- Speed first (`audioCtx: "auto"`) now uses at least 768 frames (15 s) instead of 384. On real voice (150 recorded utterances, small-q5_1, compared with the whole window) the old minimum garbled short utterances — the match ratio fell by 0.34 for 1–3 s and 0.13 for 3–6 s — while 768 matched the whole window at every length (within ±0.03, no loops left after the retry). It takes about half the time of the whole window (median 7.6 s per utterance on a 2-core runner, vs. 16–22 s for the whole window), a little slower than the old minimum. The window grows with the utterance above about 12.8 s, as before.

### macOS
- No changes.

## 0.3.4 — 2026-10-15

### macOS
- Fixed: a tag or closing line whisper made up inside the text (「…テストの収募 (音楽)」, [BLANK_AUDIO], (拍手), ご視聴ありがとうございました) was pasted. It now counts as a failed transcription: Koe retries once over the whole window with the temperature fallback and without the prompt, and if the phrase is still there it is removed before pasting.
- Fixed: when a loop started inside a word (「…選びながらドラフ、ドラフ、…」), shrinking the repeat still left two copies.

### Windows
- Fixed: a tag or closing line whisper made up inside the text (「…テストの収募 (音楽)」, seen with small-q5_1; also [BLANK_AUDIO], (拍手), ご視聴ありがとうございました) was pasted. It now counts as a failed transcription: Koe retries once with audio_ctx=0 and the temperature fallback, without the prompt, and if the phrase is still there it is removed before pasting. koe.log shows `whisper_stock_phrase`.
- windows-bench `suite: accept` also runs every sentence with the short prompt (no pack terms) to show the terms' cost; the speed condition is now a 6 s median on the 2-core runner.
- Fixed: when a loop started inside a word (「…選びながらドラフ、ドラフ、…」), shrinking the repeat still left two copies. The transcription path (prompt, audio_ctx, retries, collapse) is now one function in `core`, used by Koe and by the new acceptance check (`windows-bench`, suite `accept`).

## 0.3.3 — 2026-10-15

### macOS
- Fixed: the first utterance after about 10 minutes of silence took 3–4 s longer. Counting which glossary terms were used recently (about 500 terms against the last 300 utterances) ran right before transcription; it now runs in the background. The record keeps `prompt_ms`.
- The improvement loop adds only single terms to the personal glossary: phrases joined by particles (「〜の〜」) and ordinary words written only in kanji/hiragana are skipped (people's names are still allowed).
- Fixed: whisper sometimes looped on a short word ("ドラフ、ドラフ、…") or a few characters ("ミティミティ…") and the whole loop was pasted. Repetition is now also detected as the same word 5+ times in a row (split at 、 , space 。) or the same 2–6 characters 6+ times in a row. Koe retries once over the whole 30 s window with the temperature fallback (audio_ctx=0, temperature_inc=0.2) and without the prompt; if it still loops, the repeated part is pasted once.
- `make test` runs the text unit tests (no Xcode needed).
- Diagnostics: each utterance records how late the key-up event reached Koe (`key_up_lag_ms`), and Enter scheduling is logged with its delay.

### Windows
- The default model is now small-q5_1 (about 190 MB, also the first download). A bench on a 2-core Windows runner (windows/bench/results.md) showed small + speed first (`audioCtx: "auto"`) as the best balance: 3–5× faster than the whole window (4–7 s instead of 16–22 s per utterance) with match ratio 0.91–1.00. Only configs without `model` change; a model already in config.json (including the large-v3-turbo written by earlier versions) is kept.
- Fixed: large-v3-turbo returned empty text when speed first shrank the window. large-v3 models now always use the whole window (audio_ctx=0); the menu says 「turbo では効きません」.
- Model menu order and labels: small-q5_1（既定・速さと精度のバランス）, large-v3-turbo-q5_0（精度重視・遅い）, base-q5_1（とても速いが誤変換が多い）.
- Fixed: whisper sometimes looped on a short word ("ドラフ、ドラフ、…", seen with small-q5_1 and audio_ctx=384) or a few characters, and the whole loop was pasted. Repetition is now also detected as the same word 5+ times in a row (split at 、 , space 。) or the same 2–6 characters 6+ times in a row. Koe retries once with audio_ctx=0 and the temperature fallback (temperature_inc=0.2), without the prompt; if it still loops, the repeated part is pasted once. koe.log shows `whisper_repetition` and `fallback=` on `whisper_ok`.
- Requests now always send `temperature_inc` (0.0, or 0.2 with `temperatureFallback`) instead of relying on the server default.

## 0.3.2 — 2026-10-14

### macOS
- Newer releases are noticed the same day: Koe also checks when the menu is opened (if the last check was more than a minute ago), and the menu has "更新を確認" to check right away. The check reads the redirect of the latest release page instead of the GitHub API, so many users behind one office IP do not hit the API rate limit.

### Windows
- Update check also runs when the tray menu is opened, if the last check was 1 minute ago or more (in the background; the menu opens at once). New releases are noticed the same day instead of up to 24 hours later.
- Menu → 更新を確認 checks right away and says 「最新です（vX）」 when there is no newer version. It works even with `updateCheck` off.
- The update check no longer uses the GitHub REST API, whose limit without login (60 requests an hour per IP) is quickly used up when many people share one office IP. Koe reads the version from the redirect of `https://github.com/<repo>/releases/latest` (not followed) and offers the update only after a HEAD request confirms `releases/download/vX.Y.Z/Koe-X.Y.Z-windows-x64.zip` exists; otherwise it only logs "no windows asset".
- koe.log's `update_check` lines show what triggered the check (`reason=start|daily|menu|manual`).

## 0.3.1 — 2026-10-14

### Windows
- Faster transcription of short utterances on CPU: whisper's encoder no longer processes the full 30 s window every time. Each request sends `audio_ctx` sized to the utterance (50 frames per second + 10% + 64, between 384 and 1500; 30 s or more uses the whole window), so a few seconds of speech no longer costs as much as 30 s. Menu "速さ優先（短い発話を速く。精度が少し落ちることがある）" turns it on (default) or off; `audioCtx` in config.json: `"auto"` | `0` (whole window) | a fixed number.
- koe.log's `whisper_ok` and the diagnostics show the audio_ctx used.

### macOS
- No changes.

## 0.3.0 — 2026-10-14

### macOS
- Press mode option (menu → 押し方): hold to talk (default) or toggle — a short press starts recording and the next press stops and pastes. Typing or clicking does not cancel a toggled recording.
- Menu → 診断情報を書き出す: writes a zip to the Desktop with version, machine, settings (secrets hidden), the event log and per-utterance timings, and the whisper log. No transcripts, audio or glossary contents.
- Menu → 使い方 opens the Japanese usage guide (docs/usage-ja.md); a short welcome is shown on first launch.
- "Open at login" is turned on the first time Koe starts, so it comes back after a restart. Turning it off in the menu is respected.

### Windows
- Faster transcription on CPU: whisper-server now uses as many threads as there are logical processors (up to 16; `threads` in config.json), greedy decoding (`-bs 1 -bo 1`), flash attention, and no temperature fallback (one decoding pass instead of up to six; `temperatureFallback` turns it back on).
- Model menu "モデル（速さ⇔精度）": large-v3-turbo-q5_0 (default), small-q5_1 (faster) or base-q5_1 (fastest). A new model is downloaded on first selection and whisper-server restarts with it. `model` in config.json also accepts short names such as `small-q5_1`.
- Press mode "押し方": hold to talk (default) or tap to start / tap to stop (`pressMode`: `"hold"` | `"toggle"`). In toggle mode other keys do not cancel the recording, and a long press still works as hold to talk. Applies without restart.
- "診断情報を書き出す（送る用）" writes a zip to the desktop with the environment (CPU, RAM, model, threads, settings with secrets hidden) and the tails of koe.log / whisper-server.log / update.log. No audio and no transcribed text.
- koe.log records the CPU name, logical CPUs, RAM and threads at start, whisper-server's system_info (AVX etc.) and timings, and for each utterance the audio length, transcription time and milliseconds per audio second. It no longer records the autocorrected words (only their count).

## 0.2.3 — 2026-10-14

### macOS
- Fixed: under heavy load (load average 10–60) Enter was still absorbed by the terminal about 3% of the time. Koe now waits according to both the load and the text length (up to 2 s), and skips Enter if another app came to the front meanwhile.

### Windows
- No changes.

## 0.2.2 — 2026-10-13

### macOS
- Fixed: pressing the key again within 0.25 s of releasing it (while Koe was still recording the tail) erased the previous utterance. The previous one is now finished first.
- Fixed: a mouse click while speaking cancelled the recording silently. Only clicks within the first second count as a ⌘+click shortcut now.

### Windows
- No changes.

## 0.2.1 — 2026-10-13

### macOS
- Lock recording can be started and stopped from the menu (the double tap still works).
- Lock recording has its own start and stop sounds (two rising notes / two falling notes), so it is distinguishable from a normal recording.

### Windows
- No changes.

## 0.2.0 — 2026-10-13

### New
- **Windows (preview, x64).** Hold Right Alt (or Right Ctrl) to talk, release to paste; Enter only in terminals. Runs whisper.cpp locally on the CPU (large-v3-turbo q5_0). Same term packs, personal glossary and receiver note as on macOS. Not yet widely tested.
- **In-app update (macOS and Windows).** Koe checks GitHub Releases at launch and once a day; the menu shows "新しい版 vX があります" and replaces the app in place. Updating from 0.1.0 needs one manual install.
- **Lock recording (macOS).** Tap the key twice quickly to record hands-free, tap once more to stop. The text keeps line breaks, is saved to `~/Documents/Koe/<date-time>.txt`, copied to the clipboard and opened. Typing or clicking does not stop it; lock recordings are never sent to the improvement loop.
- **Choose the push-to-talk key (macOS).** Menu → 押して話すキー: right ⌘ / ⌥ / ⌃ / fn. Right ⌘ clashes with ⌘+Space and ⌘+Return on US keyboards.
- **Line breaks (macOS, optional).** Break lines at whisper's segment boundaries when pasting into non-terminal apps such as Google Docs. Off by default.
- **Low input level hint (macOS).** Below about −45 dB, Koe suggests raising the input volume.
- **Latency in the menu (macOS).** "離して→貼る" shows the median of the last 20 utterances.

### Fixed
- Enter was sometimes absorbed by the terminal when the Mac was under heavy load; Koe now waits longer before Enter in that case.
- Repeated-sentence hallucinations (one sentence repeated many times) are retried without the prompt.
- The personal glossary stopped growing at 60 terms; the limit is now 300.
- Common-looking words (hiragana-only, 3 characters or shorter) are no longer auto-replaced, only listed in the receiver note.
- The improvement loop no longer drops judgements when the LLM omits them, and judges in steps.

## 0.1.0 — 2026-10-13

First public release (macOS, Apple silicon).
