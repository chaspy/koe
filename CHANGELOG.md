# Changelog

Versions follow the rule in [CONTRIBUTING.md](CONTRIBUTING.md#versioning). Each release's notes on GitHub are taken from its section here.

## Unreleased

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
