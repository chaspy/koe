# Windows speed bench

`.github/workflows/windows-bench.yml` (run it by hand: Actions → windows-bench → Run workflow, or `gh workflow run windows-bench.yml`) starts whisper-server v1.9.2 on a Windows runner with Koe's arguments and posts these files to `/inference` the way Koe does. The table goes to the job summary.

- `audio/*.wav` — synthetic speech made with macOS `say -v Kyoko`, 16 kHz mono (no real recordings). `10s.wav` is also a known repetition case: small with `audio_ctx=384` and no temperature fallback loops on 「金曜日間、」.
- `sentences.tsv` — the text each file says (used for the match ratio).
- `main.go` — the runner (`go run ./bench -h`); works with a local whisper-server on macOS / Linux too.
- `summary.py` — the markdown table.
- `results.md` — past results (runner CPU, cost, full tables).
- `accept/` — the pre-tester check (`suite: accept`): 20 sentences (1–10 s; a01 is the sentence that looped on a tester's PC) transcribed through Koe's own path (`core.TranscribeUtterance`: silence trimming, prompt with the default packs, audio_ctx, autocorrect, hallucination / repetition retries) with small-q5_1 + audioCtx auto, 3 runs each, once with Koe's prompt (default sentence + pack terms) and once with the short prompt (default sentence only) to show what the terms cost. Pass, judged on Koe's prompt: no utterance loops in any whisper pass, mean match ≥ 0.9, median ≤ 6 s per utterance on the 2-core runner (a 12-thread PC is about 3× faster, so about 2 s there). The expected texts use the usual written form where kana / kanji / digits vary (お疲れ様, 3時, 一旦, 全て); `say` reads them the same.
- Private recordings: `go run ./bench/accept -dir <dir with sentences.tsv and audio/> -audioctx auto,0 -quiet -out /tmp/...` runs your own recordings through the same path on your machine. `-quiet` keeps transcripts off stdout; keep the `-out` file and the data dir outside the repository.

Regenerate a file:

```sh
say -v Kyoko -o /tmp/x.aiff "了解です。" && ffmpeg -y -i /tmp/x.aiff -ar 16000 -ac 1 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact bench/audio/01s.wav
```

Cost: windows runners on private repositories are billed per minute ($0.010/min for 2 cores as of 2026-10-15). The summary shows the job minutes and the estimate; the job stops at 45 minutes.
