# Bench results

## 2026-10-15 — run 38666216184 (windows-bench.yml)

- Runner: GitHub-hosted `windows-latest`, AMD EPYC 7763 64-Core Processor, 2 logical processors, no GPU
- whisper.cpp v1.9.2 (`whisper-bin-x64.zip`), Koe's server arguments (`-bs 1 -bo 1 -fa`), Koe's default prompt, no temperature fallback
- Job time 21.4 min (billed 22 min) → about $0.22 at $0.010/min (2-core Windows, private repository). The first attempt failed after 1 min (billed 2 min, ~$0.02).
- auto = Koe's `audioCtx: "auto"` (`min(1500, max(384, ceil(s×55)+64))`); match = difflib ratio against `sentences.tsv` without spaces / punctuation

Takeaways:
- **small-q5_1 + auto** is the best balance: 3–5× faster than the whole window (4–7 s instead of 16–22 s per utterance here) with match 0.91–1.00.
- **large-v3-turbo-q5_0 must use the whole window**: with auto it returned empty text or a stray 「。」 for every file (match 0.00). With 0 it is accurate but takes ~74 s per utterance on 2 cores.
- base-q5_1 is fast but misrecognizes even at 0 (「了解です」→「両会です」), and auto made the 3.6 s file wrong (match 0.30).
- 4 threads on a 2-core runner is no faster than 2. No repetition in any combination.

| model | threads | audio | audio s | audio_ctx | runs | median ms | ms / audio s | match | repetition | output (first run) |
|---|---:|---|---:|---|---:|---:|---:|---:|---|---|
| base-q5_1 | 2 | 01s | 0.9 | 0 (whole) | 3 | 4185 | 4810 | 0.50 | no | 両会です。 |
| base-q5_1 | 2 | 01s | 0.9 | auto (384) | 3 | 1055 | 1213 | 0.50 | no | 表会です。 |
| base-q5_1 | 2 | 03s | 3.6 | 0 (whole) | 3 | 4226 | 1187 | 1.00 | no | ログを見て、エラーが出ていないか確認してください。 |
| base-q5_1 | 2 | 03s | 3.6 | auto (384) | 3 | 1338 | 376 | 0.30 | no | ご覧いただきください。 |
| base-q5_1 | 2 | 06s | 6.6 | 0 (whole) | 3 | 4651 | 704 | 0.96 | no | プルリクエストを作ったので、時間がある時にレビューをお願いします。急ぎではありません。 |
| base-q5_1 | 2 | 06s | 6.6 | auto (428) | 3 | 1434 | 217 | 0.96 | no | プルリクエストを作ったので、時間がある時にレビューをお願いします。急ぎではありません。 |
| base-q5_1 | 2 | 10s | 9.0 | 0 (whole) | 3 | 4619 | 511 | 0.96 | no | 来週のリリースに向けて、残っている課題を洗い出して、担当と機嫌を決めてから、金曜日までに共有します。 |
| base-q5_1 | 2 | 10s | 9.0 | auto (561) | 3 | 1882 | 208 | 0.82 | no | 来週のリリースに向けて、残っている課題を扱いだして、担当と機限を決めてから、金用までに教育を行います。 |
| base-q5_1 | 4 | 01s | 0.9 | 0 (whole) | 3 | 4000 | 4598 | 0.50 | no | 両会です。 |
| base-q5_1 | 4 | 01s | 0.9 | auto (384) | 3 | 1061 | 1220 | 0.50 | no | 表会です。 |
| base-q5_1 | 4 | 03s | 3.6 | 0 (whole) | 3 | 4186 | 1176 | 1.00 | no | ログを見て、エラーが出ていないか確認してください。 |
| base-q5_1 | 4 | 03s | 3.6 | auto (384) | 3 | 1094 | 307 | 0.30 | no | ご覧いただきください。 |
| base-q5_1 | 4 | 06s | 6.6 | 0 (whole) | 3 | 4309 | 652 | 0.96 | no | プルリクエストを作ったので、時間がある時にレビューをお願いします。急ぎではありません。 |
| base-q5_1 | 4 | 06s | 6.6 | auto (428) | 3 | 1397 | 211 | 0.96 | no | プルリクエストを作ったので、時間がある時にレビューをお願いします。急ぎではありません。 |
| base-q5_1 | 4 | 10s | 9.0 | 0 (whole) | 3 | 4537 | 502 | 0.96 | no | 来週のリリースに向けて、残っている課題を洗い出して、担当と既言を決めてから、金曜日までに共有します。 |
| base-q5_1 | 4 | 10s | 9.0 | auto (561) | 3 | 1941 | 215 | 0.78 | no | 来週のリリースに向けて、残っている課題を扱いだして、担当と記言を決めてから、緊要日までに教育師。 |
| small-q5_1 | 2 | 01s | 0.9 | 0 (whole) | 3 | 15730 | 18080 | 1.00 | no | 了解です。 |
| small-q5_1 | 2 | 01s | 0.9 | auto (384) | 3 | 5133 | 5900 | 1.00 | no | 「了解」です。 |
| small-q5_1 | 2 | 03s | 3.6 | 0 (whole) | 3 | 21823 | 6130 | 1.00 | no | ログを見て、エラーが出ていないか確認してください。 |
| small-q5_1 | 2 | 03s | 3.6 | auto (384) | 3 | 4342 | 1220 | 1.00 | no | ログを見て、エラーが出ていないか確認してください。 |
| small-q5_1 | 2 | 06s | 6.6 | 0 (whole) | 3 | 16456 | 2490 | 0.96 | no | プルリクエストを作ったので、時間がある時にレビューをお願いします。急ぎではありません。 |
| small-q5_1 | 2 | 06s | 6.6 | auto (428) | 3 | 5047 | 764 | 0.91 | no | プルリクエストを作る、なので、時間がある時に、レビューをお願いします。 急ぎではありません。 |
| small-q5_1 | 2 | 10s | 9.0 | 0 (whole) | 3 | 16891 | 1868 | 1.00 | no | 来週のリリースに向けて、残っている課題を洗い出して、担当と期限を決めてから、金曜日までに共有します。 |
| small-q5_1 | 2 | 10s | 9.0 | auto (561) | 3 | 6909 | 764 | 0.95 | no | 来週のリリースに向けて、残っている課題をあらい出して、 担当と期限を決めてから、 金替日までに共有します。 |
| small-q5_1 | 4 | 01s | 0.9 | 0 (whole) | 3 | 15571 | 17898 | 1.00 | no | 了解です。 |
| small-q5_1 | 4 | 01s | 0.9 | auto (384) | 3 | 4100 | 4713 | 1.00 | no | 「了解」です。 |
| small-q5_1 | 4 | 03s | 3.6 | 0 (whole) | 3 | 16084 | 4518 | 1.00 | no | ログを見て、エラーが出ていないか確認してください。 |
| small-q5_1 | 4 | 03s | 3.6 | auto (384) | 3 | 4399 | 1236 | 1.00 | no | ログを見て、エラーが出ていないか確認してください。 |
| small-q5_1 | 4 | 06s | 6.6 | 0 (whole) | 3 | 16517 | 2499 | 0.96 | no | プルリクエストを作ったので、時間がある時にレビューをお願いします。急ぎではありません。 |
| small-q5_1 | 4 | 06s | 6.6 | auto (428) | 3 | 5143 | 778 | 0.91 | no | プルリクエストを作る、なので、時間がある時に、レビューをお願いします。 急ぎではありません。 |
| small-q5_1 | 4 | 10s | 9.0 | 0 (whole) | 3 | 16968 | 1877 | 1.00 | no | 来週のリリースに向けて、残っている課題を洗い出して、担当と期限を決めてから、金曜日までに共有します。 |
| small-q5_1 | 4 | 10s | 9.0 | auto (561) | 3 | 7050 | 780 | 0.95 | no | 来週のリリースに向けて、残っている課題をあらい出して、 担当と期限を決めてから、 金替日までに共有します。 |
| large-v3-turbo-q5_0 | 2 | 01s | 0.9 | 0 (whole) | 1 | 73134 | 84062 | 1.00 | no | 了解です。 |
| large-v3-turbo-q5_0 | 2 | 01s | 0.9 | auto (384) | 1 | 17761 | 20415 | 0.00 | no | , " |
| large-v3-turbo-q5_0 | 2 | 03s | 3.6 | 0 (whole) | 1 | 73550 | 20660 | 1.00 | no | ログを見て、エラーが出ていないか確認してください。 |
| large-v3-turbo-q5_0 | 2 | 03s | 3.6 | auto (384) | 1 | 17497 | 4915 | 0.00 | no |  |
| large-v3-turbo-q5_0 | 2 | 06s | 6.6 | 0 (whole) | 1 | 73702 | 11150 | 0.96 | no | プルリクエストを作ったので、時間がある時にレビューをお願いします。急ぎではありません。 |
| large-v3-turbo-q5_0 | 2 | 06s | 6.6 | auto (428) | 1 | 19563 | 2960 | 0.00 | no |  |
| large-v3-turbo-q5_0 | 2 | 10s | 9.0 | 0 (whole) | 1 | 74207 | 8209 | 1.00 | no | 来週のリリースに向けて、残っている課題を洗い出して、担当と期限を決めてから、金曜日までに共有します。 |
| large-v3-turbo-q5_0 | 2 | 10s | 9.0 | auto (561) | 1 | 26155 | 2893 | 0.00 | no | 。 |

## 2026-10-16 — minimum window for audioCtx auto (real voice + CI)

Real voice: 150 of the maintainer's own recorded utterances (1.1–20 s), run only on that Mac (CPU-only whisper-server v1.9.2, Metal off, small-q5_1, Koe's path and prompt); reference = what the macOS app (large-v3-turbo) pasted. Recordings and texts never left the machine; only these aggregates are kept. Drop = mean match of the whole window (0) minus the policy's (positive = worse).

| policy | drop all | 1–3 s (23) | 3–6 s (40) | 6–10 s (40) | 10–20 s (47) |
|---|---:|---:|---:|---:|---:|
| auto, min 384 (old) | +0.089 | +0.336 | +0.127 | +0.034 | −0.016 |
| **auto, min 768 (new)** | −0.025 | −0.002 | −0.029 | −0.023 | −0.032 |
| auto, min 1000 | +0.010 | −0.002 | −0.002 | +0.033 | +0.008 |
| whole window under 6 s, else min 384 | +0.018 | +0.026 | +0.012 | +0.071 | −0.025 |

min 768 and 1000: mean of two runs (the runs differed by ≤ 0.001 per length); no loop or stock phrase left after the retry, nothing empty. With min 384 the short-utterance failures were a different short phrase of about the right length, not loops.

Speed (run 38770834199, Intel Xeon Platinum 8573C, 2 logical processors; synthetic `accept` sentences, 1 run each; 7.5 min, billed 8 min ≈ $0.08):

| policy | median | 1–3 s | 3–6 s | 6–10 s |
|---|---:|---:|---:|---:|
| auto, min 768 | 7.59 s | 7.21 | 7.63 | 8.10 |
| auto, min 1000 | 9.56 s | 9.16 | 9.69 | 10.20 |

For reference, the whole window took 16–22 s per utterance on the 2-core EPYC runner (2026-10-15 above).
