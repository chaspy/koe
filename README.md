<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
    <img src="docs/logo.png" alt="koe" width="320">
  </picture>
</p>

# koe

Local voice input for macOS and Windows (preview) using [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Audio never leaves your machine. Hold a key to talk, release to paste into any app.

## Platforms

Both are built from the same code at the same version and attached to the same GitHub Release.

| | macOS (Apple silicon) | Windows x64 (preview) |
|---|---|---|
| Hold a key to talk, paste on release, Enter only in terminals | ✅ right ⌘ (or ⌥ / ⌃ / fn) | ✅ right Alt (or right Ctrl) |
| Term packs, personal glossary, note for the receiving AI | ✅ | ✅ |
| Retry on hallucination, previous utterance as context, history | ✅ | ✅ |
| In-app update | ✅ from 0.2.0 | ✅ from 0.2.0 |
| Improvement loop (glossary grows by itself) | ✅ | not yet |
| Lock recording, line breaks, low-level hint, fallback mic | ✅ | not yet |
| Speech model | large-v3-turbo on the GPU (Metal) | large-v3-turbo q5_0 on the CPU |

The Windows version is documented in [windows/README-windows.md](windows/README-windows.md).

## Koe.app (macOS menu bar, push to talk)

`macos/` contains a menu bar app that works from any app, not just a terminal. Requires whisper.cpp (see [Setup whisper.cpp](#setup-whispercpp)).

- Hold **right ⌘** to record, release to transcribe. The text is pasted into the focused field and Enter is sent (toggle in the menu).
- Pressing any other key while holding right ⌘ cancels (so ⌘ shortcuts keep working).
- The key can be changed in the menu (押して話すキー): right ⌘ / right ⌥ / right ⌃ / fn. On US keyboards right ⌘ may clash with ⌘+Space or ⌘+Return.
- Enter is sent only to terminals (iTerm, Terminal, Ghostty, …). In other apps the text is only pasted.
- **Lock recording**: tap the key twice quickly to record hands-free (e.g. taking notes while talking); tap once more to stop. The text keeps line breaks, is saved to `~/Documents/Koe/<date-time>.txt`, copied to the clipboard and opened. Typing or clicking does not stop it. Lock recordings are never sent to the improvement loop.
- **Line breaks** (menu, off by default): break lines at whisper's segment boundaries when pasting into non-terminal apps such as Google Docs.
- If your voice is recorded too quietly (below about −45 dB), Koe tells you to raise the input volume.
- The mic stays open in the background and keeps the last 0.5 s, so the first word is not cut off. Recording also continues 0.4 s after release. Turn this off from the menu if you do not want the mic indicator always on.
- Plays a short marimba tone on start and stop (toggle in the menu).
- Muted headsets: many meeting-certified headsets and speakerphones mute in hardware when you mute in the meeting app, so the OS only receives digital silence. Choose the microphone from the menu (マイク). Pick a mic other than the one your meeting app uses and Koe never goes silent. In 自動 (default), Koe uses the system default mic, detects hardware mute (near-zero signal for 1 s) and records from another microphone while it lasts; the menu shows which one (`fallbackMicName` if set, otherwise another USB mic such as a webcam, then the built-in mic). A fallback that is also silent (e.g. a closed MacBook lid) is skipped. If you have only one microphone there is nothing to fall back to. If you listen to the meeting on speakers, the fallback mic may pick up other people's voices; headphones avoid that.
- Misses are not silent: a failure tone plays, the menu shows the reason, and every press is logged to `~/Library/Application Support/Koe/events.jsonl` (`koe_eval.py misses`).
- Keeps `whisper-server` resident (port 18080), so the model is loaded once. Prefers `ggml-large-v3-turbo.bin` when present.
- Needs Microphone and Accessibility permissions.

**Install from the dmg**: open `Koe-<version>.dmg`, drag Koe to Applications, launch it, and allow Microphone and Accessibility. On first launch Koe downloads the speech model (about 1.6 GB, shown in the menu). whisper-server is bundled; nothing else to install.

**Build from source**:

```bash
# once: a self-contained whisper-server (static, Metal embedded) to bundle
cd ~/.local/src/whisper.cpp
cmake -B build-static -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build build-static -j --target whisper-server

cd macos
make install SIGN_IDENTITY="<your codesigning identity>"   # installs to ~/Applications and launches
make dist SIGN_IDENTITY="<your codesigning identity>"      # build/Koe-<version>.dmg
```

The dmg is not notarized yet; on another Mac, right-click → Open the first time.

Settings (`defaults write io.github.chaspy.koe <key> <value>`): `hotkeyKeyCode` (54 = right ⌘, 61 = right ⌥), `model`, `language`, `prompt`, `port`, `minHoldSeconds`, `warmMic`, `sounds`, `startSound` / `stopSound` (bundled `start`/`stop` or a macOS sound name such as `Ping`).

### LLM cleanup (optional)

Turn on "LLM で整形" in the menu to pass the transcript through an LLM that removes fillers, fixes obvious mistakes and adds punctuation. It talks to any OpenAI-compatible endpoint; the default is a local [Ollama](https://ollama.com):

```bash
ollama pull qwen2.5:7b
```

If the LLM fails or times out, the raw transcript is pasted instead.

Settings: `llmEndpoint` (default `http://localhost:11434/v1`), `llmModel` (default `qwen2.5:7b`), `llmAPIKey`, `llmTimeout` (seconds, default 8).

### Term packs

Official, shareable glossaries for a field live in `packs/` and are bundled with the app (menu → 用語パック). `developer` (Git / GitHub / CI/CD: プルリク, マージ, コンフリクト, リベース…) is on by default. Each entry can list misrecognized forms; forms starting with `~` are ambiguous and only go into the note for the receiving AI. See [CONTRIBUTING.md](CONTRIBUTING.md) to add terms or packs.

### Glossary

Two more layers, same format (one term per line, optionally a tab and aliases separated by `／`, `#` for comments):

- **Organization glossary** (`orgGlossary`: a file path or an http(s) URL, refreshed daily): shared, read-only. Put your company's product names, system names and jargon here so everyone gets them right from day one.
- **Personal glossary** (`~/Library/Application Support/Koe/glossary.txt`, path configurable via `glossaryPath`): grown automatically from your own usage.

**Misrecognitions are fixed at both ends.** Aliases in the personal glossary are real misrecognitions recorded by the improvement loop:

- Koe replaces them with the correct term before pasting (not inside longer katakana/latin words, so `フォールバック` stays).
- Koe writes `~/.claude/koe-voice-glossary.md` (path: `receiverGlossaryPath`), a short note for the AI that receives your dictation. Import it from your `CLAUDE.md` with `@~/.claude/koe-voice-glossary.md`, and Claude reads new variants of the same words correctly — no extra cost or latency.

The whisper prompt only fits about 120 characters, so Koe picks the terms that appeared most in your recent utterances (counting aliases too) from both layers; the LLM cleanup gets all of them.

Personal glossary details: `~/Library/Application Support/Koe/glossary.txt` is sent to whisper as part of the initial prompt on every request, and to the LLM cleanup. Put the words you say often and want spelled a certain way at the top — only about 120 characters fit in the whisper prompt. Changes apply to the next utterance without restarting.

### Improvement loop (built in)

Turn on "使うほど賢くする（改善ループ）" in the menu. Every `improveBatch` (default 30) new utterances, while you are not recording, Koe sends the transcripts — plus, if you dictate into Claude Code, the message actually sent, Claude's reply and your next message from `~/.claude/projects` — to an OpenAI-compatible LLM, and gets back:

- misrecognized terms and their correct spelling → added to your personal glossary (with the misrecognized forms as aliases) once seen twice, or once if you corrected it explicitly
- per-utterance communication judgement (understood / corrected / unclear) → stored in history; the menu shows 7-day communication success

**People directory** (optional): `peopleSources` lists a tab-separated file of `<ID><TAB><name>` lines (`#` comments), fetched daily like packs (`gh:owner/repo/path` or `https://`). When set, **the whole directory (every ID and name) is sent to the improvement loop's LLM on every run**, so it can tell which person a misrecognized name refers to. A person's name is added to the personal glossary only when the LLM is confident, the misrecognized form is followed by an honorific (〜さん etc.) and the utterance or its surroundings talk about working with someone (Slack, review, PR, meeting…), so 「パン粉を買う」 is never taken for a name; the alias only applies before the honorific. Because a rare name shows up only a few times, one confident detection is enough: the LLM also lists up to 5 forms the same name is likely to be misrecognized as (パン粉さん → パンコさん, パンコアさん, バンコさん), they go through the same checks, and all of them are added as honorific-only aliases at once. A nickname you said on purpose is never rewritten to the real name: a misrecognized form is mapped to a real name only when it contains kanji (the same reading in other characters, e.g. 山舌さん → 山下さん) and is not a calling form already learned for that person; kana/latin-only forms are treated as possible nicknames and left alone unless you corrected them yourself. The directory is not used for the whisper prompt or the LLM cleanup, and is not written to events, stdout or the diagnostics (only its size; `peopleSources` is hidden there). Koe writes `~/.claude/koe-people.md` (everyone plus the forms learned so far) for the receiving AI to grep when it meets an unknown name, and adds one line pointing to it to `koe-voice-glossary.md`.

Which LLM: by default Koe runs your Claude Code headlessly (`improveProvider` = `command`, `improveCommand` = `claude -p --model sonnet`) — if you dictate into Claude Code you already have it, and it adds no per-token cost. Any CLI that reads the prompt on stdin and prints the answer works (set `improveCommand`). Or use an OpenAI-compatible API (`improveProvider` = `api`): `improveEndpoint` (OpenAI, a LiteLLM proxy, a local Ollama `http://localhost:11434/v1`…), `improveModel`, and `improveAPIKey` or `improveTokenCommand` (a command that prints a bearer token). It is off by default and asks for confirmation, showing where the data goes. Small local models are weak at this; use a capable model.

**Shared packs**: `packSources` lists packs Koe re-fetches daily into `~/Library/Application Support/Koe/packs/` — `gh:owner/repo/path/pack.txt` (private repos via the `gh` CLI, which must be logged in) or an `https://` URL. Enable them with `enabledPacks`. Keep a team pack in a shared repo and let everyone's improvement loop send pull requests with newly observed misrecognitions.

**Distributing settings**: menu → 設定ファイルを読み込む… imports a JSON file with any of `orgGlossary`, `improveProvider`, `improveCommand`, `improveEndpoint`, `improveModel`, `improveAPIKey`, `improveTokenCommand`, `improveEnabled`, `llmEndpoint`, `llmModel`, … A relative `orgGlossary` is copied from next to the JSON. Commands in the file are shown before import. The same keys can be pushed with an MDM configuration profile for `io.github.chaspy.koe`.

```json
{ "orgGlossary": "org_glossary.txt", "improveProvider": "command", "improveCommand": "claude -p --model sonnet" }
``` `Koe --improve-now` runs it once from the command line.

The menu also shows today's input success (presses that ended in a paste).

`eval/koe_improve.py` is an older script that grows the glossary from your history using a local Ollama model (nothing leaves your machine): it extracts likely misrecognitions, and appends the corrected term once it has been seen at least twice.

### History and evaluation

With "録音と結果を保存（評価用）" on (default), each utterance is saved to `~/Library/Application Support/Koe/history/YYYY-MM-DD/` as `<id>.wav` + `<id>.json` (raw transcript, cleaned text, timings, models, prompts). About 32 KB per second of audio. Everything stays local.

`eval/koe_eval.py` scores accuracy as CER (character error rate) against reference texts you add:

```bash
python3 eval/koe_eval.py list --unlabeled              # samples without a reference
python3 eval/koe_eval.py set-ref <id> "正しいテキスト"   # add a reference
python3 eval/koe_eval.py score                         # score what was pasted at the time
python3 eval/koe_eval.py run --tag base                # re-run whisper on labeled samples
python3 eval/koe_eval.py run --tag qwen --llm-model qwen2.5:7b
python3 eval/koe_eval.py run --tag small --model ~/.local/src/whisper.cpp/models/ggml-small.bin
```

Results are saved under `~/Library/Application Support/Koe/evals/`.

If you dictate into [Claude Code](https://claude.com/claude-code), `koe_eval.py context` matches each utterance with your Claude Code session logs (`~/.claude/projects/`) and shows the message actually sent, Claude's reply and your next message. Manual edits, the way Claude interpreted it, and your corrections are strong hints for what you meant, which makes drafting references (`set-draft`) much easier.

## License

MIT
