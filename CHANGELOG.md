# Changelog

Versions follow the rule in [CONTRIBUTING.md](CONTRIBUTING.md#versioning). Each release's notes on GitHub are taken from its section here.

## Unreleased

### macOS
- No changes.

### Windows
- Optional low recording level hint: enable `lowLevelWarning` in config.json (off by default). Whole-recording RMS below -45 dBFS shows input-volume advice at most once every 10 minutes; only the numeric level is logged.

## 0.7.0 — 2026-10-17

### Repository
- Developer pack (both apps): misrecognitions seen in the test set are added — マージュ → マージ, クロードコード → Claude Code, and new terms アプルーブ (アプローブ), STG (エステージ), インシデント (インシエント), リファクタ (リラクター), BQ (`~B級`, only a note for the receiving AI). On the stored turbo outputs of the test set (755 clips) the developer terms are spelled right 38 times instead of 33 out of 44.
- `koe_bench.py term-forms` lists "reference word → form whisper actually produced" from the test set's stored turbo outputs without running whisper (words and counts only), and `compare-terms` gains `--developer` (another pack file), `--extra-terms` (score the same words before and after), `--forms` (missed term → form, no transcripts) and `--sleep`. `eval/compare_pack_change.sh` runs the before/after comparison of a pack change (runs thinly beside other work: nice 19, 2 threads, 1 s pause per clip).
- `koe_eval.py daily` shows 貼る→届く (median / p90) and 届かず for pastes into a terminal: the time from ⌘V (`paste_at`) until the text shows up as a user message (`type=user` or a queued `queue-operation`) in any Claude Code session log (`~/.claude/projects/*/*.jsonl`) within 5 minutes. A paste counts as delivered when its normalized text is contained in the sent message (several queued utterances merged into one also match) or nearly equal to it (small hand edits). Undelivered pastes are split by reason for today: no user message in any session / a similar message was sent (edited) / messages were sent but none matched. Whether a paste went to a non-Claude-Code pane or was deleted without sending cannot be told apart. Records from before `paste_at` use the history id time, which is set right after the paste. Only numbers and counts are printed; the session logs and the pasted text are used only for matching.

### macOS
- Transcription is a little faster: whisper's window is now sized to the utterance (same rule as Windows: at least 15 s, the whole 30 s window from 30 s on). On an M2 Max with large-v3-turbo the median went 0.55 → 0.51 s and p95 0.73 → 0.63 s with the same accuracy. `defaults write io.github.chaspy.koe audioCtx 0` goes back to the whole window; repetition retries always use the whole window.
- Optional, off by default: with `defaults write io.github.chaspy.koe measureVisible -bool true`, after pasting into iTerm Koe reads the current iTerm session's screen (AppleScript `contents`) every 150 ms for up to 10 s and records how long until the end of the pasted text appears (`visible_ms`, events `visible` / `not_visible`), so "pasted" and "you can see it" can be told apart. Panes inside Herdr are found too (the screen is split on box-drawing borders and the text may wrap across rows of the same pane). Not shown within 10 s counts as a failure in 今日の入力成功 and in `koe_eval.py daily` (new columns 貼る→画面に出る median / p90 and 出ず). The screen and the pasted text are used only for comparison and are never written anywhere. When turned on, the first measurement asks for the Automation permission for iTerm (Info.plist `NSAppleEventsUsageDescription`); while it is off Koe never asks and the menu shows no screen numbers. Without the permission the paste works as before and the measurement is recorded as `visible_unknown`, not as a failure. When iTerm is slow to answer, Koe waits as long as the last read took before reading again; the longest read is recorded as `visible_read_ms_max`. Other terminals are not measured.
- History and the `pasted` event record `paste_at`: when ⌘V was sent, in UTC with milliseconds (the same format as Claude Code's session log timestamps).

### Windows
- Trial engine: `"engine": "parakeet"` in config.json transcribes with Parakeet-ja (NVIDIA, CC BY 4.0) through sherpa-onnx in Koe's own process, on the CPU — no prompt, the glossary still corrects afterwards. The model (466 MB) is downloaded from the sherpa-onnx GitHub release on first use. The default stays `"whisper"`; the zip now also ships `sherpa-onnx-c-api.dll`, `onnxruntime.dll` and `THIRD_PARTY_NOTICES.md`.

## 0.6.0 — 2026-10-17

### Repository
- Docs: `docs/data-ja.md` (Japanese) lists what Koe keeps on your computer, what it sends and when, and what the diagnostics zip contains; the 「外に送りません」 line in `docs/usage-ja.md` now says that the improvement loop is the exception.
- `koe_eval.py perf` now splits release-to-paste into stages (tail recording, prompt, transcription, the rest) by condition: Mac load in three bands, the first utterance after 10 minutes idle, audio of 30 s or more, the improve loop running, and whisper restarted. Findings for BUG-4 are in docs/notes/2026-10-16-latency-breakdown.md.
- Fixed: `koe_eval.py misses` showed a paste success rate of about 30% because it divided by every event type in `events.jsonl` (`tracks`, `enter_scheduled`, …). It now uses the same definition as the daily report's ①入力された (pasted records ÷ pasted + failed presses), prints it per day, and counts `no_accessibility` and `target_changed` as failures (also in `daily` and `trend`).

### macOS
- When a newer version is found, Koe asks once — when it is settled (not recording or transcribing, 30 s after the last use) — 「新しい版 vX があります」 with the first line of that version's macOS changes: 「今すぐ更新」 / 「あとで」. "Later" keeps it quiet until the next launch or 24 hours. The dialog is not modal (push-to-talk keeps working), does not take the focus from the app you are typing in, and Enter / Esc never start the update: the default is 「あとで」 and 「今すぐ更新」 needs a click. Versions with no macOS changes are not asked about. Koe never updates itself without asking; the menu item 「新しい版 vX があります」 stays.
- People directory (opt-in, `peopleSources`: `gh:owner/repo/path` or `https://`, a `<ID><TAB><name>` file fetched daily): when set, **the improvement loop sends the whole directory (every ID and name) to its LLM on every run** and asks who a misrecognized name refers to. Names enter the personal glossary only when the LLM is confident, an honorific follows (〜さん) and the conversation is about working with someone (Slack, review, PR…); the alias applies only before the honorific, and nicknames are never rewritten to real names (a surname misrecognized as other kanji, e.g. 山舌さん → 山下さん, is corrected; kana/latin-only forms and calling forms already learned for that person are not). Koe writes `~/.claude/koe-people.md` for the receiving AI to grep for unknown names (one line in `koe-voice-glossary.md` points to it). The directory is not used for the whisper prompt, and only its size appears in events and diagnostics (`peopleSources` is hidden there).
- Names learned faster (IMP-8): when the improvement loop is confident about one misrecognized name followed by an honorific, it also adds up to 5 similar-sounding forms the LLM expects for the same person (パン粉さん → パンコさん, パンコアさん, バンコさん), and the name replaces from the first detection instead of waiting for a second one. The forms pass the same checks (not a directory ID or real name, not a known calling form, no kana/latin-only form for a real name) and apply only before the honorific, so 「パン粉を買う」 stays unchanged.
- Network: the update check now also downloads the new version's `CHANGELOG.md` from raw.githubusercontent.com (for the one-line summary in the update prompt).

### Windows
- When a newer version is found, Koe asks once — when it is settled (not recording or transcribing, 30 s after the last use) — 「新しい版 vX があります」 with the first line of that version's Windows changes, Yes = update now / No = later. The dialog does not take the foreground, No is the default (Enter = later) and Esc does nothing, so typing elsewhere never starts the update. "Later" keeps it quiet until the next start or 24 hours. Versions with no Windows changes are not asked about. Koe never updates itself without asking; the tray item 「新しい版 vX があります」 stays.
- Fixed: the diagnostics zip showed the initial prompt (`prompt`) you wrote in config.json. Like the mac, the settings section now shows only the length of `prompt`, `contextPrompt` and other keys that can hold your words (glossary paths, commands), and also hides keys containing `auth`.
- Network: the update check now also downloads the new version's `CHANGELOG.md` from raw.githubusercontent.com (for the one-line summary in the update prompt).

## 0.5.0 — 2026-10-16

### macOS
- Fixed: after every update macOS silently dropped Koe's Accessibility permission, so pasting failed without any sign. Builds were ad-hoc signed, so each build looked like a different app. Koe is now signed with a fixed certificate ("Koe Code Signing"), so the permission survives updates. **Updating to this version needs the Accessibility permission once more (remove Koe in System Settings → Privacy & Security → Accessibility and add it again); after that, updates keep it.**
- When the Accessibility permission is missing, Koe no longer records the paste as done: the utterance is logged as `no_accessibility`, the text stays on the clipboard (⌘V), and Koe shows how to re-add the permission (also once at launch).
- If the frontmost app at paste time is not the app you started talking in (you switched apps while Koe was transcribing), Koe no longer pastes into it: the text stays on the clipboard (⌘V) and in 「最近の文字起こし」, the utterance is recorded as `target_changed` (counted as a failure), and Koe says 「貼り先が変わったので貼りませんでした」. Compared by app (bundle id), so another window or tab of the same app still gets the paste. History and events now record `paste_app` next to `app`.
- The history (`~/Library/Application Support/Koe/history`) no longer grows forever (one Mac had 614 MB after 10 days). By default recordings (.wav / .alt.wav) are kept 14 days and the text and records (.json) 30 days, and when the folder is over 1 GB the oldest recordings go first. Menu → 「履歴を残す期間」: 7 / 14 (default) / 30 / 90 days / forever; text is kept about twice as long as recordings. Pruning runs in the background at launch and once a day, never touches files changed within the last day (the improvement loop and evaluation may be using them), and never touches the lock-recording texts in ~/Documents/Koe. Diagnostics show the setting and the history size. `Koe --history-prune-dry-run` prints what would be removed.

### Windows
- If the foreground app at paste time is not the app you were in when you started talking (you switched apps while Koe was transcribing), Koe no longer pastes into it: the text stays on the clipboard (Ctrl+V) and in 「最近の文字起こし」, the utterance is recorded as `target_changed`, and Koe says 「貼り先が変わったので貼りませんでした」. Compared by app (exe name), so another window or tab of the same app still gets the paste. koe.log `paste` lines show `start_app=`.
- The same history retention: `historyKeepDays` (default 14; recordings 14 days, text 30 days, 1 GB cap, 0 = keep everything) replaces the old `historyDays` (7 days, whole day folders, only at start). Pruning runs in the background at start and once a day; menu → 「履歴を残す期間」; diagnostics show the setting and the history size.

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
