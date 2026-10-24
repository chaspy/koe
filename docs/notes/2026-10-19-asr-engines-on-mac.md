# 日本語の音声認識エンジンを Mac で比べる（#180）

Koe の Mac 版で使えそうな日本語の音声認識エンジン 5 つを、同じデータ・同じ物差しで比べた。数値だけを載せる（書き起こしは保存も表示もしていない）。

## 測り方

- **再現**: `python3 eval/public_bench.py`（初回だけ。JSUT を取る）のあと `python3 eval/asr_bench.py`。エンジンは 1 つずつ常駐させ、`nice 15`・4 スレッド。空き＋inactive が 6 GB を切ったら止める
- **データ**（公開・合成のみ。実在の人の声は使わない）
  - JSUT v1.1 BASIC5000 の固定 200 件から、前後の無音を落とした 60 件（5 秒未満）と、続けてつないだ 5〜28 秒の 20 件ずつ（`audio_ctx_bench.py` と同じ作り方）。計 200 発話
  - 用語: `packs/developer.txt` から規則で選んだ 60 語を「〜の設定を確認してください。」などの文にし、macOS の声 Kyoko（`say`）で読ませたもの。仮説に語がそのまま含まれれば正解とした（NFKC・大文字小文字・空白を無視）。合成音声なので、実際の声より易しい
- **条件**
  - none: プロンプトなし
  - base: Koe の基本プロンプト
  - pack: 開発者パックをプロンプトに入れ、パックの自動置換もかける（Koe の既定）。プロンプトの無いエンジンは、自動置換だけ
- **物差し**
  - CER: 正規化前（空白だけ除く）と正規化後（NFKC・記号を除く）
  - 長さ別の時間: 中央値 / p90。HTTP や標準入出力のやりとりを含む。手前で 1 回だけ空打ちしてから測った
  - 用語の正解数、常駐メモリの最大（エンジンのプロセス）、モデルの大きさ、ライセンス
- **エンジン**
  - whisper-turbo-metal: いまの Koe（whisper.cpp 0c7be69、large-v3-turbo、Metal、窓は全体）
  - whisper-turbo-coreml: 同じモデルで、エンコーダーだけ whisper.cpp 配布の Core ML 版（Neural Engine）
  - kotoba-whisper-v2-metal: kotoba-whisper v2.0（ggml、量子化なし）
  - apple-speechanalyzer: macOS 26 の SpeechAnalyzer / SpeechTranscriber（ja_JP、端末内）
  - parakeet-ja-sherpa-cpu: Parakeet-ja（int8、CTC、貪欲）を sherpa-onnx 1.13.8 で CPU 4 スレッド（Koe の Windows と同じモデル）
- **測った日と環境**: 2026-10-19、Apple silicon の Mac（メモリ 32 GB）。ほかの作業と同時に動いていた時間がある。whisper-turbo-coreml は、1 回目の測定中に空きメモリが 6 GB を切ったので止め、空きが戻ってから単独で測り直した

## 結果

| Engine | Condition | CER raw (%) | CER normalised (%) | Terms right | Median s (<5 s) | p90 s (<5 s) | Median s (12.8-16 s) | Median s (24-28 s) | Peak RSS (MB) | Model (MB) | Licence |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| whisper-turbo-metal | none | 14.82 | 6.34 | 24/60 | 0.510 | 0.550 | 0.679 | 0.855 | 1843 | 1624 | MIT |
| whisper-turbo-metal | base | 9.81 | 6.32 | 22/60 | 0.520 | 0.543 | 0.678 | 0.855 | 1843 | 1624 | MIT |
| whisper-turbo-metal | pack | 9.74 | 6.66 | 27/60 | 0.530 | 0.546 | 0.686 | 0.871 | 1843 | 1624 | MIT |
| kotoba-whisper-v2-metal | none | 25.17 | 17.53 | 13/60 | 0.494 | 0.528 | 0.627 | 0.679 | 1749 | 1519 | Apache-2.0 |
| kotoba-whisper-v2-metal | base | 35.13 | 28.41 | 13/60 | 0.495 | 0.519 | 0.620 | 1.112 | 1749 | 1519 | Apache-2.0 |
| kotoba-whisper-v2-metal | pack | 100.00 | 100.00 | 0/60 | 0.475 | 0.483 | 0.482 | 0.486 | 1749 | 1519 | Apache-2.0 |
| whisper-turbo-coreml | none | 15.00 | 6.34 | 24/60 | 0.652 | 0.676 | 0.836 | 1.047 | 1818 | 2797 | MIT |
| whisper-turbo-coreml | base | 10.29 | 6.95 | 22/60 | 0.661 | 0.704 | 0.832 | 1.052 | 1818 | 2797 | MIT |
| whisper-turbo-coreml | pack | 9.73 | 6.63 | 26/60 | 0.703 | 0.770 | 0.852 | 1.033 | 1818 | 2797 | MIT |
| apple-speechanalyzer | none | 11.35 | 6.47 | 16/60 | 0.138 | 0.155 | 0.342 | 0.485 | 19 | 0 | Apple (part of macOS) |
| apple-speechanalyzer | pack | 11.35 | 6.47 | 18/60 | 0.147 | 0.177 | 0.317 | 0.514 | 19 | 0 | Apple (part of macOS) |
| parakeet-ja-sherpa-cpu | none | 15.35 | 6.55 | 12/60 | 0.104 | 0.134 | 0.448 | 0.865 | 1271 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |
| parakeet-ja-sherpa-cpu | pack | 15.35 | 6.55 | 14/60 | 0.103 | 0.137 | 0.419 | 0.753 | 1271 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |

### 長さ別の時間（秒）

| Engine | Condition | <5 s median / p90 (s) | 5-7.5 s median / p90 (s) | 7.5-10 s median / p90 (s) | 10-12.8 s median / p90 (s) | 12.8-16 s median / p90 (s) | 16-20 s median / p90 (s) | 20-24 s median / p90 (s) | 24-28 s median / p90 (s) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo-metal | none | 0.510 / 0.550 | 0.560 / 0.577 | 0.594 / 0.614 | 0.622 / 0.642 | 0.679 / 0.732 | 0.766 / 0.832 | 0.795 / 0.847 | 0.855 / 0.939 |
| whisper-turbo-metal | base | 0.520 / 0.543 | 0.567 / 0.580 | 0.588 / 0.603 | 0.627 / 0.640 | 0.678 / 0.703 | 0.751 / 1.002 | 0.801 / 0.923 | 0.855 / 0.883 |
| whisper-turbo-metal | pack | 0.530 / 0.546 | 0.583 / 0.620 | 0.602 / 0.623 | 0.641 / 0.654 | 0.686 / 0.699 | 0.752 / 0.787 | 0.796 / 0.818 | 0.871 / 0.937 |
| kotoba-whisper-v2-metal | none | 0.494 / 0.528 | 0.532 / 0.542 | 0.549 / 0.577 | 0.572 / 0.587 | 0.627 / 0.788 | 0.644 / 0.680 | 0.661 / 0.679 | 0.679 / 0.694 |
| kotoba-whisper-v2-metal | base | 0.495 / 0.519 | 0.531 / 0.558 | 0.551 / 0.575 | 0.580 / 0.597 | 0.620 / 1.080 | 1.080 / 1.240 | 1.070 / 1.136 | 1.112 / 1.349 |
| kotoba-whisper-v2-metal | pack | 0.475 / 0.483 | 0.477 / 0.484 | 0.477 / 0.487 | 0.486 / 0.506 | 0.482 / 0.488 | 0.482 / 0.491 | 0.484 / 0.491 | 0.486 / 0.494 |
| whisper-turbo-coreml | none | 0.652 / 0.676 | 0.710 / 0.750 | 0.738 / 0.771 | 0.781 / 0.931 | 0.836 / 0.860 | 0.920 / 1.113 | 0.967 / 1.059 | 1.047 / 1.078 |
| whisper-turbo-coreml | base | 0.661 / 0.704 | 0.722 / 0.822 | 0.740 / 0.920 | 0.794 / 0.839 | 0.832 / 1.033 | 0.897 / 1.233 | 0.952 / 1.086 | 1.052 / 1.184 |
| whisper-turbo-coreml | pack | 0.703 / 0.770 | 0.731 / 0.799 | 0.753 / 0.775 | 0.793 / 0.817 | 0.852 / 0.946 | 0.888 / 0.936 | 0.995 / 1.067 | 1.033 / 1.161 |
| apple-speechanalyzer | none | 0.138 / 0.155 | 0.170 / 0.183 | 0.196 / 0.213 | 0.258 / 0.286 | 0.342 / 0.377 | 0.417 / 0.449 | 0.406 / 0.466 | 0.485 / 0.510 |
| apple-speechanalyzer | pack | 0.147 / 0.177 | 0.200 / 0.248 | 0.224 / 0.243 | 0.259 / 0.282 | 0.317 / 0.364 | 0.362 / 0.388 | 0.432 / 0.457 | 0.514 / 0.603 |
| parakeet-ja-sherpa-cpu | none | 0.104 / 0.134 | 0.195 / 0.213 | 0.262 / 0.494 | 0.412 / 0.641 | 0.448 / 0.614 | 0.518 / 0.622 | 0.627 / 0.658 | 0.865 / 1.000 |
| parakeet-ja-sherpa-cpu | pack | 0.103 / 0.137 | 0.196 / 0.219 | 0.242 / 0.279 | 0.322 / 0.350 | 0.419 / 0.447 | 0.495 / 0.532 | 0.652 / 0.805 | 0.753 / 0.800 |

### 長さ別の CER（正規化後、%）と空の答えの数

| Engine | Condition | <5 s CER % (empty) | 5-7.5 s CER % (empty) | 7.5-10 s CER % (empty) | 10-12.8 s CER % (empty) | 12.8-16 s CER % (empty) | 16-20 s CER % (empty) | 20-24 s CER % (empty) | 24-28 s CER % (empty) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo-metal | none | 6.3 (0) | 6.5 (0) | 6.6 (0) | 5.5 (0) | 7.0 (0) | 7.2 (0) | 6.4 (0) | 5.6 (0) |
| whisper-turbo-metal | base | 6.5 (0) | 7.4 (0) | 6.5 (0) | 5.6 (0) | 6.7 (0) | 7.3 (0) | 6.2 (0) | 5.5 (0) |
| whisper-turbo-metal | pack | 6.9 (0) | 7.5 (0) | 7.1 (0) | 5.5 (0) | 7.1 (0) | 8.1 (0) | 6.1 (0) | 5.9 (0) |
| kotoba-whisper-v2-metal | none | 7.1 (0) | 7.9 (0) | 9.3 (0) | 8.5 (0) | 11.8 (0) | 16.0 (0) | 20.0 (0) | 33.5 (0) |
| kotoba-whisper-v2-metal | base | 7.5 (0) | 11.3 (0) | 9.4 (0) | 8.5 (0) | 15.4 (0) | 20.5 (0) | 41.1 (0) | 59.0 (0) |
| kotoba-whisper-v2-metal | pack | 100.0 (60) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) |
| whisper-turbo-coreml | none | 6.4 (0) | 6.5 (0) | 6.4 (0) | 5.8 (0) | 6.8 (0) | 7.4 (0) | 6.2 (0) | 5.7 (0) |
| whisper-turbo-coreml | base | 6.7 (0) | 7.2 (0) | 6.3 (0) | 5.7 (0) | 10.7 (0) | 7.4 (0) | 6.2 (0) | 6.0 (0) |
| whisper-turbo-coreml | pack | 7.0 (0) | 7.6 (0) | 6.7 (0) | 5.5 (0) | 7.3 (0) | 8.1 (0) | 6.0 (0) | 5.8 (0) |
| apple-speechanalyzer | none | 6.5 (0) | 7.1 (0) | 6.1 (0) | 5.2 (0) | 7.7 (0) | 7.2 (0) | 5.9 (0) | 6.3 (0) |
| apple-speechanalyzer | pack | 6.5 (0) | 7.1 (0) | 6.1 (0) | 5.2 (0) | 7.7 (0) | 7.2 (0) | 5.9 (0) | 6.3 (0) |
| parakeet-ja-sherpa-cpu | none | 7.5 (0) | 7.4 (0) | 7.3 (0) | 5.7 (0) | 7.4 (0) | 7.4 (0) | 5.4 (0) | 6.0 (0) |
| parakeet-ja-sherpa-cpu | pack | 7.5 (0) | 7.4 (0) | 7.3 (0) | 5.7 (0) | 7.4 (0) | 7.4 (0) | 5.4 (0) | 6.0 (0) |

## 読み取れること

- **精度（CER 正規化後）は、turbo（Metal・Core ML）・SpeechAnalyzer・Parakeet がほぼ同じ 6.3〜6.6%**。どの長さでも大きく崩れない
- **速さは SpeechAnalyzer と Parakeet が大きく上**。5 秒未満の中央値は SpeechAnalyzer 0.14 秒・Parakeet 0.10 秒で、turbo の 0.51 秒の 4〜5 分の 1。28 秒近い発話でも SpeechAnalyzer は 0.49 秒（turbo 0.86 秒）
- **用語は whisper（プロンプトに開発者パックを入れたとき）がいちばん良い**。turbo + pack は 27/60、SpeechAnalyzer は 18/60（自動置換だけ）、Parakeet は 14/60。プロンプトを渡せないエンジンは、パックの語を知らないまま書く
- **正規化前の CER**（記号・数字の書き方を含む）は、turbo の pack / base が 9.7〜9.8% で、プロンプトなし（14.8%）より書き方が JSUT の正解に近い。SpeechAnalyzer は 11.4%、Parakeet は 15.4%
- **Core ML エンコーダーは、この Mac では Metal より遅い**（5 秒未満で 0.65 秒 対 0.51 秒）。精度は同じで、モデルが 1.2 GB 増える。初回は Core ML のコンパイルで時間とメモリを使う（1 回目の測定はメモリ不足で止めた）
- **kotoba-whisper v2.0 は Koe の使い方に合わない**。長い発話ほど崩れ（24〜28 秒で CER 33.5%）、Koe の基本プロンプトでさらに悪くなり、開発者パックのプロンプトでは全発話が空になった。短い発話（5 秒未満）だけなら 7.1% で、turbo に近い
- **メモリ**: turbo 約 1.8 GB、Parakeet 約 1.3 GB。SpeechAnalyzer の 19 MB は呼び出し側だけの値で、モデルは macOS のプロセスの中にあるので比べられない
- **既存の値との関係**: Koe の Mac の「離して→貼る」の中央値は 906 ms で、そのうち文字起こしが 534 ms（turbo）。この測定の turbo（5 秒未満 0.51 秒）と合う。Windows の Parakeet-ja は 0.52 秒（#180 に書かれた既存の値）

## iPhone（koe-ios）で動くか（見込み。測っていない）

| エンジン | 見込み |
|---|---|
| whisper（turbo） | whisper.cpp・WhisperKit とも iOS で動くが、1.6 GB のモデルは iPhone 15 では重い |
| kotoba-whisper | 同じ（1.5 GB） |
| SpeechAnalyzer | iOS 26 にある同じ API。モデルは OS 側 |
| Parakeet-ja（sherpa-onnx） | sherpa-onnx は iOS 対応。int8 で 655 MB |

## 推奨

1. **既定は、今の whisper-turbo-metal のまま**。精度は同じで、開発者パックのプロンプトが効く（用語 27/60）のは whisper だけ。Koe の主な使い方（開発の話をエージェントに送る）では、用語の差が効く
2. **SpeechAnalyzer は、「速さ優先」の選べるエンジンとして試す価値がある**。精度は同じで、短い発話が 0.37 秒ほど速い（貼るまでの時間の 4 割）。用語が弱いので、次の一手は、SpeechAnalyzer の語彙の手がかり（AnalysisContext の contextualStrings）に開発者パックを渡して、用語の正解数が whisper に近づくかを同じハーネスで測ること。koe-ios の第一候補でもある
3. **Parakeet-ja** は、Mac では SpeechAnalyzer とほぼ同じ立ち位置で、用語がさらに弱く、CPU で 1.3 GB 使う。Mac で新しく入れる理由は薄い（Windows では引き続き選べるまま）
4. **Core ML エンコーダーと kotoba-whisper v2.0** は採らない

## 追加測定: SpeechAnalyzer に開発者パックを語彙の手がかりとして渡す（2026-10-19）

再現: `python3 eval/asr_bench.py --engines apple-speechanalyzer apple-dictation`（下の 2 つの表がどちらも出る）

推奨 2 の続き。SpeechAnalyzer の API で語彙を渡せる口は `AnalysisContext.contextualStrings`（タグ `.general`、`analyzer.setContext` で渡す）。macOS 26.2 の SDK で、SpeechAnalyzer の上に載るモジュールは 2 つある。

- SpeechTranscriber: #190 で測ったもの
- DictationTranscriber: macOS の音声入力と同じ系統のモデル（preset `shortDictation`）。こちらには `customizedLanguage`（独自の言語モデルを作って渡す）もあるが、今回は測っていない

条件 hints = 開発者パックの全語（重なりを除いて約 140 語）を contextualStrings に入れ、さらに自動置換。whisper の pack 条件は、プロンプトの長さの都合でパックの先頭の約 120 文字分しか入らないので、語の数では hints の方が多く渡している。

| Engine | Condition | CER raw (%) | CER normalised (%) | Terms right | Median s (<5 s) | p90 s (<5 s) | Median s (12.8-16 s) | Median s (24-28 s) |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo-metal（#190 の値） | pack | 9.74 | 6.66 | 27/60 | 0.530 | 0.546 | 0.686 | 0.871 |
| apple-speechanalyzer | none | 11.35 | 6.47 | 16/60 | 0.159 | 0.178 | 0.351 | 0.486 |
| apple-speechanalyzer | pack | 11.35 | 6.47 | 18/60 | 0.157 | 0.178 | 0.341 | 0.524 |
| apple-speechanalyzer | hints | 11.35 | 6.47 | 18/60 | 0.145 | 0.163 | 0.318 | 0.508 |
| apple-dictation | none | 13.55 | 8.46 | 14/60 | 0.456 | 0.554 | 0.989 | 1.554 |
| apple-dictation | pack | 13.57 | 8.47 | 15/60 | 0.452 | 0.532 | 1.019 | 1.605 |
| apple-dictation | hints | 13.57 | 8.48 | 15/60 | 0.762 | 0.821 | 1.304 | 1.846 |

手がかりが本当に届いているかを、用語の 60 文で別に確かめた。これは `asr_bench.py` には入っていない。手順は次のとおりで、`eval/speechanalyzer_cli.swift` だけで再現できる。2 回測り、正解数は 2 回とも同じだった。DictationTranscriber は、手がかりを渡すと実行ごとに出力が少し揺れるので、変わった文の数は幅で書いた:

1. `swiftc -O -o speechanalyzer_cli eval/speechanalyzer_cli.swift`
2. 用語の 60 文の WAV（キャッシュの `asr-terms/`。`asr_bench.py` を 1 回動かすとできる。中身は `term_items(packs/developer.txt)` の順。2026-10-24 から、ファイル名は文の SHA-256 の先頭 16 文字）を、モジュールごと（引数 `speech` / `dictation`）に、次の 3 通りで 1 行ずつ渡す。1 行は「WAV のパス」、または「WAV のパス + タブ + 手がかりをタブ区切り」
   - 手がかりなし: パスだけ
   - パックの全語: パスのあとに `hint_line(entries)`（パックの語を重なりなく、パックの順に）
   - 答えの語だけ: パスのあとに、その文に入れた語 1 つだけ（文の中の語を知っている、実際には使えない上限の条件）
3. 自動置換はかけない。各文について、`fold(語) in fold(出力)` で正解を数え、手がかりなしのときの出力と文字列が違う文の数を数える。出力の比較はメモリの中だけで済ませ、書き起こしは残さない

| Module | 手がかりなし | パックの全語 | 答えの語だけ |
|---|---|---|---|
| SpeechTranscriber | 16/60 | 16/60（変わった文 0） | 16/60（変わった文 0） |
| DictationTranscriber | 14/60 | 14/60（変わった文 2〜5） | 18/60（変わった文 8〜9） |

### 読み取れること

- **SpeechTranscriber は contextualStrings を使っていない**。答えの語そのものを渡しても、60 文のどれも 1 文字も変わらなかった。SpeechTranscriber で用語を良くする手は、今の API には無い（自動置換だけ）
- **DictationTranscriber は使っているが、パックの量だと効かない**。語を 1 つに絞ると 8〜9 文が変わり 14→18 になるが、約 140 語を渡すと 2〜5 文しか変わらず、正解数は増えない。手がかりを渡すと 5 秒未満で 0.3 秒遅くなる（0.45→0.76 秒）
- **DictationTranscriber はそもそも SpeechTranscriber より遅く、精度も低い**（CER 8.5% 対 6.5%、5 秒未満 0.46 秒 対 0.16 秒）。Koe で使う理由は無い
- SpeechAnalyzer の数値は #190 と同じ（CER は一致、時間は数十 ms の揺れ）

### 推奨の更新

- 推奨 1（既定は whisper-turbo-metal のまま）は変わらない。用語では、プロンプトに開発者パックを入れた whisper（27/60）に、Apple のどちらのモジュールも届かない（最良 18/60）
- 推奨 2 は弱める。SpeechAnalyzer（SpeechTranscriber）は「速さ優先、用語は自動置換だけ」の選択肢としてなら残るが、語彙の手がかりで用語を良くする道は無い。用語を良くしたいなら、自動置換の表を厚くする方が効く
- DictationTranscriber の `customizedLanguage`（パックから独自の言語モデルを作る）は未検証。モデルを作る手間と時間がかかり、元の精度と速さが SpeechTranscriber より悪いので、優先度は低い

## 追加測定: 予備の候補と Parakeet の Core ML（2026-10-24）

再現: `python3 eval/asr_bench.py --engines whisper-turbo-metal apple-speechanalyzer parakeet-ja-sherpa-cpu parakeet-ja-sherpa-coreml moonshine-tiny-ja-sherpa-cpu qwen3-asr-0.6b-sherpa-cpu reazonspeech-zipformer-sherpa-cpu`

- 新しいエンジン（どれも sherpa-onnx 1.13.8、`eval/sherpa_cli.py`、4 スレッド、貪欲。モデルは SHA-256 で固定してキャッシュに）
  - moonshine-tiny-ja-sherpa-cpu: Moonshine tiny ja（quantized、2026-02-27）
  - qwen3-asr-0.6b-sherpa-cpu: Qwen3-ASR 0.6B int8（2026-03-25）。hotwords を受け取るので、hints 条件 = 開発者パックの全語を hotwords に
  - reazonspeech-zipformer-sherpa-cpu: ReazonSpeech の zipformer（k2、日本語のみ、2024-08-01、transducer）
  - parakeet-ja-sherpa-coreml: Parakeet-ja を ONNX Runtime の Core ML 実行プロバイダーで（#180 の「Core ML EP if it works」）
- 用語の 60 文は、#234 で開発者パックに HTML が入ったため 1 文だけ入れ替わった（59/60 は同じ）。比べられるように、whisper-turbo-metal・SpeechAnalyzer・Parakeet（CPU）も同じ文で測り直した（下の表の値。#190 の値とは用語が ±1〜2 違う）
- 空きメモリ（free + inactive）が他の作業で 5〜9 GB の間を上下し、6 GB の止めで何度も止まったので、`--min-available-gb 4` で測った（memory_pressure の空きはずっと 50% 以上）

| Engine | Condition | CER raw (%) | CER normalised (%) | Terms right | Median s (<5 s) | p90 s (<5 s) | Median s (12.8-16 s) | Median s (24-28 s) | Peak RSS (MB) | Model (MB) | Licence |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| whisper-turbo-metal | none | 14.82 | 6.34 | 25/60 | 0.546 | 0.760 | 0.749 | 0.857 | 1800 | 1624 | MIT |
| whisper-turbo-metal | base | 9.81 | 6.32 | 23/60 | 0.533 | 0.561 | 0.776 | 0.867 | 1800 | 1624 | MIT |
| whisper-turbo-metal | pack | 9.74 | 6.66 | 28/60 | 0.531 | 0.556 | 0.698 | 0.865 | 1800 | 1624 | MIT |
| apple-speechanalyzer | none | 11.35 | 6.47 | 17/60 | 0.133 | 0.149 | 0.296 | 0.449 | 19 | 0 | Apple (part of macOS) |
| apple-speechanalyzer | pack | 11.35 | 6.47 | 19/60 | 0.133 | 0.146 | 0.291 | 0.434 | 19 | 0 | Apple (part of macOS) |
| apple-speechanalyzer | hints | 11.35 | 6.47 | 19/60 | 0.135 | 0.150 | 0.295 | 0.434 | 19 | 0 | Apple (part of macOS) |
| parakeet-ja-sherpa-cpu | none | 15.35 | 6.55 | 13/60 | 0.109 | 0.149 | 0.462 | 0.789 | 1247 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |
| parakeet-ja-sherpa-cpu | pack | 15.35 | 6.55 | 15/60 | 0.111 | 0.143 | 0.451 | 0.790 | 1247 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |
| parakeet-ja-sherpa-coreml | none | 15.30 | 6.49 | 13/60 | 0.270 | 0.338 | 1.007 | 2.227 | 8280 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |
| parakeet-ja-sherpa-coreml | pack | 15.30 | 6.49 | 15/60 | 0.263 | 0.321 | 0.896 | 1.994 | 8280 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |
| moonshine-tiny-ja-sherpa-cpu | none | 85.53 | 84.57 | 14/60 | 0.049 | 0.075 | 0.062 | 0.126 | 403 | 71 | Moonshine Community License (non-commercial; model), Apache-2.0 (sherpa-onnx) |
| moonshine-tiny-ja-sherpa-cpu | pack | 85.53 | 84.57 | 14/60 | 0.049 | 0.072 | 0.064 | 0.131 | 403 | 71 | Moonshine Community License (non-commercial; model), Apache-2.0 (sherpa-onnx) |
| qwen3-asr-0.6b-sherpa-cpu | none | 16.25 | 12.92 | 17/60 | 0.562 | 1.082 | 1.986 | 4.021 | 3923 | 982 | Apache-2.0 (model, sherpa-onnx) |
| qwen3-asr-0.6b-sherpa-cpu | pack | 16.25 | 12.92 | 20/60 | 0.538 | 0.795 | 2.104 | 3.994 | 3923 | 982 | Apache-2.0 (model, sherpa-onnx) |
| qwen3-asr-0.6b-sherpa-cpu | hints | 72.10 | 71.22 | 21/60 | 1.126 | 2.340 | 2.101 | 1.582 | 3923 | 982 | Apache-2.0 (model, sherpa-onnx) |
| reazonspeech-zipformer-sherpa-cpu | none | 31.14 | 24.25 | 10/60 | 0.054 | 0.072 | 0.203 | 0.328 | 923 | 169 | Apache-2.0 (model, sherpa-onnx) |
| reazonspeech-zipformer-sherpa-cpu | pack | 31.14 | 24.25 | 10/60 | 0.068 | 0.113 | 0.192 | 0.335 | 923 | 169 | Apache-2.0 (model, sherpa-onnx) |

長さ別の CER（正規化後、%）と空の答えの数:

| Engine | Condition | <5 s CER % (empty) | 5-7.5 s CER % (empty) | 7.5-10 s CER % (empty) | 10-12.8 s CER % (empty) | 12.8-16 s CER % (empty) | 16-20 s CER % (empty) | 20-24 s CER % (empty) | 24-28 s CER % (empty) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo-metal | none | 6.3 (0) | 6.5 (0) | 6.6 (0) | 5.5 (0) | 7.0 (0) | 7.2 (0) | 6.4 (0) | 5.6 (0) |
| whisper-turbo-metal | base | 6.5 (0) | 7.4 (0) | 6.5 (0) | 5.6 (0) | 6.7 (0) | 7.3 (0) | 6.2 (0) | 5.5 (0) |
| whisper-turbo-metal | pack | 6.9 (0) | 7.5 (0) | 7.1 (0) | 5.5 (0) | 7.1 (0) | 8.1 (0) | 6.1 (0) | 5.9 (0) |
| apple-speechanalyzer | none | 6.5 (0) | 7.1 (0) | 6.1 (0) | 5.2 (0) | 7.7 (0) | 7.2 (0) | 5.9 (0) | 6.3 (0) |
| apple-speechanalyzer | pack | 6.5 (0) | 7.1 (0) | 6.1 (0) | 5.2 (0) | 7.7 (0) | 7.2 (0) | 5.9 (0) | 6.3 (0) |
| apple-speechanalyzer | hints | 6.5 (0) | 7.1 (0) | 6.1 (0) | 5.2 (0) | 7.7 (0) | 7.2 (0) | 5.9 (0) | 6.3 (0) |
| parakeet-ja-sherpa-cpu | none | 7.5 (0) | 7.4 (0) | 7.3 (0) | 5.7 (0) | 7.4 (0) | 7.4 (0) | 5.4 (0) | 6.0 (0) |
| parakeet-ja-sherpa-cpu | pack | 7.5 (0) | 7.4 (0) | 7.3 (0) | 5.7 (0) | 7.4 (0) | 7.4 (0) | 5.4 (0) | 6.0 (0) |
| parakeet-ja-sherpa-coreml | none | 7.8 (0) | 7.2 (0) | 7.2 (0) | 5.5 (0) | 7.3 (0) | 7.2 (0) | 5.4 (0) | 5.9 (0) |
| parakeet-ja-sherpa-coreml | pack | 7.8 (0) | 7.2 (0) | 7.2 (0) | 5.5 (0) | 7.3 (0) | 7.2 (0) | 5.4 (0) | 5.9 (0) |
| moonshine-tiny-ja-sherpa-cpu | none | 11.9 (0) | 27.3 (0) | 54.9 (7) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) |
| moonshine-tiny-ja-sherpa-cpu | pack | 11.9 (0) | 27.3 (0) | 54.9 (7) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) | 100.0 (20) |
| qwen3-asr-0.6b-sherpa-cpu | none | 13.1 (0) | 14.5 (0) | 12.9 (0) | 9.1 (0) | 10.8 (0) | 13.9 (0) | 11.1 (0) | 16.3 (0) |
| qwen3-asr-0.6b-sherpa-cpu | pack | 13.1 (0) | 14.5 (0) | 12.9 (0) | 9.1 (0) | 10.8 (0) | 13.9 (0) | 11.1 (0) | 16.3 (0) |
| qwen3-asr-0.6b-sherpa-cpu | hints | 16.8 (1) | 14.9 (0) | 35.1 (0) | 14.5 (1) | 75.4 (0) | 99.3 (2) | 100.0 (6) | 100.0 (4) |
| reazonspeech-zipformer-sherpa-cpu | none | 12.4 (0) | 38.3 (0) | 32.4 (0) | 23.7 (0) | 31.1 (0) | 31.7 (0) | 17.3 (0) | 19.7 (0) |
| reazonspeech-zipformer-sherpa-cpu | pack | 12.4 (0) | 38.3 (0) | 32.4 (0) | 23.7 (0) | 31.1 (0) | 31.7 (0) | 17.3 (0) | 19.7 (0) |

### 読み取れること

- **どれも今の既定（whisper-turbo-metal + pack）を置き換えない**。精度で並ぶのは前回どおり turbo・SpeechAnalyzer・Parakeet（6.3〜6.7%）だけ
- **Moonshine tiny ja は短い発話専用**。5 秒未満なら 11.9% で、とても速い（0.05 秒）が、10 秒を超えると答えが空になる（20 発話すべて）。日本語のモデルは **Moonshine Community License（非商用）**。Koe には入れられない
- **Qwen3-ASR 0.6B は遅く、精度も turbo の約 2 倍の誤り**（12.9%）。28 秒近い発話で 4 秒、常駐 3.9 GB。hotwords に開発者パックを入れると用語は 20→21/60 と少し増えるが、長い発話が壊れる（16 秒以上でほぼ 100%）。この ONNX は プロンプト＋音声で 512 トークンが上限で、パックの hotwords（約 280 トークン）で音声が切り詰められる（sherpa-onnx のログで確認）
- **ReazonSpeech の zipformer は速いが JSUT では誤りが多い**（24.3%、正規化前 31.1%）
- **Parakeet の Core ML 実行プロバイダーは動くが、CPU より遅く、メモリを大きく使う**（5 秒未満 0.27 秒 対 0.11 秒、28 秒近くで 2.2 秒 対 0.79 秒、常駐 8.3 GB 対 1.2 GB）。精度は同じ。採らない
- **#191 から main で whisper のエンジンが動かなくなっていた**（`run_engine` が `engine.hints` を読むが、whisper のエンジンに `hints` が無く AttributeError）。この測定で直した（`WhisperServerEngine.hints = False`）

### 推奨

前回の推奨（既定は whisper-turbo-metal のまま、速さ優先なら SpeechAnalyzer）は変わらない。予備の候補 3 つと Parakeet の Core ML は採らない。

## 追加測定: 雑音を足した条件（2026-10-24）

再現: `python3 eval/asr_bench.py --noise OOFFICE --engines whisper-turbo-metal apple-speechanalyzer parakeet-ja-sherpa-cpu`（結果は `<engine>@noise` として保存）

- 同じ 200 発話と用語の 60 文に、**DEMAND** の OOFFICE（オフィス、ch01、CC BY 4.0）を SNR 20・15・10 dB で混ぜた（`eval/voice_isolation_bench.py` と同じ混ぜ方・同じ SHA-256 で固定したキャッシュ。発話ごとに決まった区間）
- 条件は Koe の既定だけ（pack: whisper はパックのプロンプト + 自動置換、プロンプトの無いエンジンは自動置換。SpeechAnalyzer は hints も）
- 雑音なしの値は上の「予備の候補と Parakeet の Core ML」の表（同じ文で測ったもの）

| Engine | Condition | CER raw (%) | CER normalised (%) | Terms right | Median s (<5 s) | p90 s (<5 s) | Median s (12.8-16 s) | Median s (24-28 s) | Peak RSS (MB) | Model (MB) | Licence |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| whisper-turbo-metal@noise | pack@OOFFICE_20dB | 9.75 | 6.56 | 26/60 | 0.550 | 0.584 | 0.702 | 0.871 | 1884 | 1624 | MIT |
| whisper-turbo-metal@noise | pack@OOFFICE_15dB | 9.83 | 6.65 | 26/60 | 0.540 | 0.610 | 0.764 | 0.895 | 1884 | 1624 | MIT |
| whisper-turbo-metal@noise | pack@OOFFICE_10dB | 9.79 | 6.68 | 26/60 | 0.555 | 0.589 | 0.734 | 0.872 | 1884 | 1624 | MIT |
| apple-speechanalyzer@noise | pack@OOFFICE_20dB | 11.44 | 6.53 | 21/60 | 0.149 | 0.193 | 0.300 | 0.430 | 20 | 0 | Apple (part of macOS) |
| apple-speechanalyzer@noise | hints@OOFFICE_20dB | 11.44 | 6.53 | 21/60 | 0.133 | 0.148 | 0.299 | 0.435 | 20 | 0 | Apple (part of macOS) |
| apple-speechanalyzer@noise | pack@OOFFICE_15dB | 11.45 | 6.57 | 21/60 | 0.142 | 0.173 | 0.357 | 0.531 | 20 | 0 | Apple (part of macOS) |
| apple-speechanalyzer@noise | hints@OOFFICE_15dB | 11.45 | 6.57 | 21/60 | 0.135 | 0.153 | 0.305 | 0.441 | 20 | 0 | Apple (part of macOS) |
| apple-speechanalyzer@noise | pack@OOFFICE_10dB | 11.54 | 6.62 | 21/60 | 0.132 | 0.147 | 0.367 | 0.579 | 20 | 0 | Apple (part of macOS) |
| apple-speechanalyzer@noise | hints@OOFFICE_10dB | 11.54 | 6.62 | 21/60 | 0.144 | 0.173 | 0.328 | 0.449 | 20 | 0 | Apple (part of macOS) |
| parakeet-ja-sherpa-cpu@noise | pack@OOFFICE_20dB | 15.21 | 6.42 | 16/60 | 0.154 | 0.328 | 0.449 | 0.778 | 1216 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |
| parakeet-ja-sherpa-cpu@noise | pack@OOFFICE_15dB | 15.31 | 6.50 | 17/60 | 0.105 | 0.138 | 0.427 | 0.762 | 1216 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |
| parakeet-ja-sherpa-cpu@noise | pack@OOFFICE_10dB | 15.36 | 6.53 | 16/60 | 0.105 | 0.138 | 0.434 | 0.770 | 1216 | 655 | CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx) |

長さ別の CER（正規化後、%）と空の答えの数:

| Engine | Condition | <5 s CER % (empty) | 5-7.5 s CER % (empty) | 7.5-10 s CER % (empty) | 10-12.8 s CER % (empty) | 12.8-16 s CER % (empty) | 16-20 s CER % (empty) | 20-24 s CER % (empty) | 24-28 s CER % (empty) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo-metal@noise | pack@OOFFICE_20dB | 7.1 (0) | 7.6 (0) | 6.7 (0) | 5.5 (0) | 7.1 (0) | 7.5 (0) | 6.2 (0) | 5.8 (0) |
| whisper-turbo-metal@noise | pack@OOFFICE_15dB | 6.7 (0) | 7.9 (0) | 6.9 (0) | 5.6 (0) | 7.3 (0) | 7.6 (0) | 6.3 (0) | 5.9 (0) |
| whisper-turbo-metal@noise | pack@OOFFICE_10dB | 6.8 (0) | 7.6 (0) | 6.8 (0) | 5.8 (0) | 7.7 (0) | 7.8 (0) | 6.2 (0) | 5.8 (0) |
| apple-speechanalyzer@noise | pack@OOFFICE_20dB | 6.4 (0) | 7.0 (0) | 6.1 (0) | 5.5 (0) | 7.7 (0) | 7.2 (0) | 5.9 (0) | 6.5 (0) |
| apple-speechanalyzer@noise | hints@OOFFICE_20dB | 6.4 (0) | 7.0 (0) | 6.1 (0) | 5.5 (0) | 7.7 (0) | 7.2 (0) | 5.9 (0) | 6.5 (0) |
| apple-speechanalyzer@noise | pack@OOFFICE_15dB | 6.3 (0) | 6.9 (0) | 6.3 (0) | 5.7 (0) | 7.8 (0) | 7.3 (0) | 6.1 (0) | 6.3 (0) |
| apple-speechanalyzer@noise | hints@OOFFICE_15dB | 6.3 (0) | 6.9 (0) | 6.3 (0) | 5.7 (0) | 7.8 (0) | 7.3 (0) | 6.1 (0) | 6.3 (0) |
| apple-speechanalyzer@noise | pack@OOFFICE_10dB | 6.2 (0) | 6.9 (0) | 6.6 (0) | 5.5 (0) | 7.8 (0) | 7.5 (0) | 6.0 (0) | 6.5 (0) |
| apple-speechanalyzer@noise | hints@OOFFICE_10dB | 6.2 (0) | 6.9 (0) | 6.6 (0) | 5.5 (0) | 7.8 (0) | 7.5 (0) | 6.0 (0) | 6.5 (0) |
| parakeet-ja-sherpa-cpu@noise | pack@OOFFICE_20dB | 7.2 (0) | 7.1 (0) | 6.8 (0) | 5.8 (0) | 7.3 (0) | 7.1 (0) | 5.6 (0) | 5.8 (0) |
| parakeet-ja-sherpa-cpu@noise | pack@OOFFICE_15dB | 7.2 (0) | 7.5 (0) | 7.4 (0) | 5.7 (0) | 7.3 (0) | 7.0 (0) | 5.5 (0) | 6.1 (0) |
| parakeet-ja-sherpa-cpu@noise | pack@OOFFICE_10dB | 7.3 (0) | 7.5 (0) | 7.3 (0) | 5.7 (0) | 7.2 (0) | 6.8 (0) | 5.8 (0) | 6.1 (0) |

### 読み取れること

- **オフィスの雑音は 10 dB まで、どのエンジンもほとんど変わらない**。正規化後の CER は雑音なしからの差が 0.1 pt 以内（turbo 6.66→6.56〜6.68%、SpeechAnalyzer 6.47→6.53〜6.62%、Parakeet 6.55→6.42〜6.53%）。速さも変わらない
- 用語の正解数は ±2 の揺れ（turbo 28→26、SpeechAnalyzer 19→21、Parakeet 15→16〜17）。60 文では差と言えない
- **雑音でエンジンの順位は変わらない**。推奨（既定は whisper-turbo-metal）はそのまま
- 限界: オフィスの雑音は定常で穏やか。カフェの雑踏（`--noise PCAFETER`）・部屋の響き・実際のマイクは測っていない。混ぜ方はデジタル

## 追加測定: WhisperKit（koe-ios のエンジン、2026-10-24）

再現: `python3 eval/asr_bench.py --engines whisperkit-turbo whisperkit-turbo-626mb`

- WhisperKit 1.1.1（Core ML。`eval/whisperkit_cli/` の常駐ヘルパーを SwiftPM で cache にビルド。版は `Package.swift` と `Package.resolved` で固定）
- モデル: argmaxinc/whisperkit-coreml の `openai_whisper-large-v3-v20240930`（turbo、1.6 GB、whisper.cpp の turbo と同じ元のモデル）と、iPhone 向けに縮めた `_626MB`。Hugging Face のリビジョン 0f63a78 で、ファイルごとの SHA-256 を `eval/whisperkit_models.json` に固定（大きいファイルは Hugging Face が公開する LFS の SHA-256 と一致を確認）
- 日本語、温度 0・フォールバックなし、タイムスタンプなし。base / pack のプロンプトは prompt tokens として渡す（whisper.cpp の初期プロンプトと同じ置き方）
- 比べやすいように whisper-turbo-metal（#242 で同じ文で測った値）も並べた。時間はこの Mac（M シリーズ）のもので、iPhone 15 の時間ではない

| Engine | Condition | CER raw (%) | CER normalised (%) | Terms right | Median s (<5 s) | p90 s (<5 s) | Median s (12.8-16 s) | Median s (24-28 s) | Peak RSS (MB) | Model (MB) | Licence |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| whisper-turbo-metal | none | 14.82 | 6.34 | 25/60 | 0.546 | 0.760 | 0.749 | 0.857 | 1800 | 1624 | MIT |
| whisper-turbo-metal | base | 9.81 | 6.32 | 23/60 | 0.533 | 0.561 | 0.776 | 0.867 | 1800 | 1624 | MIT |
| whisper-turbo-metal | pack | 9.74 | 6.66 | 28/60 | 0.531 | 0.556 | 0.698 | 0.865 | 1800 | 1624 | MIT |
| whisperkit-turbo | none | 14.77 | 6.39 | 25/60 | 1.255 | 1.381 | 2.291 | 3.266 | 139 | 1619 | MIT (WhisperKit, model) |
| whisperkit-turbo | base | 33.68 | 31.20 | 25/60 | 1.764 | 1.943 | 2.583 | 3.516 | 139 | 1619 | MIT (WhisperKit, model) |
| whisperkit-turbo | pack | 38.59 | 36.33 | 27/60 | 3.120 | 3.502 | 3.973 | 3.734 | 139 | 1619 | MIT (WhisperKit, model) |
| whisperkit-turbo-626mb | none | 14.52 | 6.78 | 26/60 | 1.308 | 1.503 | 2.327 | 3.209 | 141 | 626 | MIT (WhisperKit, model) |
| whisperkit-turbo-626mb | base | 34.89 | 32.50 | 25/60 | 1.849 | 2.155 | 1.791 | 3.578 | 141 | 626 | MIT (WhisperKit, model) |
| whisperkit-turbo-626mb | pack | 39.37 | 37.24 | 26/60 | 3.125 | 3.403 | 3.603 | 3.499 | 141 | 626 | MIT (WhisperKit, model) |

長さ別の時間（秒）:

| Engine | Condition | <5 s median / p90 (s) | 5-7.5 s median / p90 (s) | 7.5-10 s median / p90 (s) | 10-12.8 s median / p90 (s) | 12.8-16 s median / p90 (s) | 16-20 s median / p90 (s) | 20-24 s median / p90 (s) | 24-28 s median / p90 (s) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo-metal | none | 0.546 / 0.760 | 0.628 / 0.660 | 0.643 / 0.702 | 0.733 / 0.786 | 0.749 / 0.827 | 0.765 / 0.849 | 0.794 / 1.100 | 0.857 / 1.201 |
| whisper-turbo-metal | base | 0.533 / 0.561 | 0.617 / 0.667 | 0.645 / 0.914 | 0.704 / 0.761 | 0.776 / 0.959 | 0.901 / 1.234 | 0.806 / 1.110 | 0.867 / 1.163 |
| whisper-turbo-metal | pack | 0.531 / 0.556 | 0.579 / 0.609 | 0.604 / 0.637 | 0.649 / 0.660 | 0.698 / 0.722 | 0.752 / 0.796 | 0.808 / 1.158 | 0.865 / 0.896 |
| whisperkit-turbo | none | 1.255 / 1.381 | 1.550 / 1.645 | 1.709 / 1.956 | 1.853 / 2.025 | 2.291 / 2.447 | 2.463 / 3.088 | 2.768 / 2.923 | 3.266 / 3.916 |
| whisperkit-turbo | base | 1.764 / 1.943 | 2.069 / 2.145 | 2.245 / 2.520 | 2.505 / 2.749 | 2.583 / 3.128 | 2.972 / 3.386 | 3.345 / 3.778 | 3.516 / 4.154 |
| whisperkit-turbo | pack | 3.120 / 3.502 | 3.387 / 3.765 | 3.605 / 4.176 | 3.690 / 4.029 | 3.973 / 4.662 | 4.415 / 5.287 | 4.379 / 5.169 | 3.734 / 4.582 |
| whisperkit-turbo-626mb | none | 1.308 / 1.503 | 1.668 / 1.745 | 1.767 / 1.885 | 2.042 / 2.228 | 2.327 / 2.453 | 2.639 / 2.746 | 2.911 / 3.578 | 3.209 / 3.559 |
| whisperkit-turbo-626mb | base | 1.849 / 2.155 | 2.167 / 2.380 | 2.311 / 2.685 | 2.682 / 2.888 | 1.791 / 3.060 | 3.152 / 3.413 | 3.429 / 3.625 | 3.578 / 3.785 |
| whisperkit-turbo-626mb | pack | 3.125 / 3.403 | 3.439 / 3.898 | 3.720 / 4.213 | 3.959 / 4.384 | 3.603 / 4.391 | 4.506 / 4.867 | 4.594 / 5.383 | 3.499 / 4.894 |

長さ別の CER（正規化後、%）と空の答えの数:

| Engine | Condition | <5 s CER % (empty) | 5-7.5 s CER % (empty) | 7.5-10 s CER % (empty) | 10-12.8 s CER % (empty) | 12.8-16 s CER % (empty) | 16-20 s CER % (empty) | 20-24 s CER % (empty) | 24-28 s CER % (empty) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| whisper-turbo-metal | none | 6.3 (0) | 6.5 (0) | 6.6 (0) | 5.5 (0) | 7.0 (0) | 7.2 (0) | 6.4 (0) | 5.6 (0) |
| whisper-turbo-metal | base | 6.5 (0) | 7.4 (0) | 6.5 (0) | 5.6 (0) | 6.7 (0) | 7.3 (0) | 6.2 (0) | 5.5 (0) |
| whisper-turbo-metal | pack | 6.9 (0) | 7.5 (0) | 7.1 (0) | 5.5 (0) | 7.1 (0) | 8.1 (0) | 6.1 (0) | 5.9 (0) |
| whisperkit-turbo | none | 7.8 (1) | 6.6 (0) | 6.3 (0) | 5.5 (0) | 6.8 (0) | 7.6 (0) | 5.8 (0) | 5.6 (0) |
| whisperkit-turbo | base | 10.4 (2) | 17.6 (2) | 15.8 (2) | 14.8 (2) | 45.1 (8) | 27.6 (4) | 34.2 (6) | 48.0 (8) |
| whisperkit-turbo | pack | 12.2 (3) | 22.6 (3) | 16.6 (2) | 19.8 (3) | 46.3 (8) | 25.8 (3) | 40.7 (4) | 62.1 (7) |
| whisperkit-turbo-626mb | none | 6.5 (0) | 7.1 (0) | 6.6 (0) | 6.1 (0) | 8.0 (0) | 7.9 (0) | 6.0 (0) | 6.3 (0) |
| whisperkit-turbo-626mb | base | 8.5 (1) | 17.5 (2) | 25.7 (3) | 15.4 (2) | 54.6 (10) | 23.5 (3) | 33.8 (6) | 49.1 (9) |
| whisperkit-turbo-626mb | pack | 10.3 (2) | 17.9 (2) | 20.8 (2) | 20.1 (3) | 51.8 (10) | 21.9 (2) | 41.2 (4) | 65.8 (8) |

### 読み取れること

- **プロンプトなしなら精度は whisper.cpp と同じ**（正規化後 6.39%、縮めた 626 MB でも 6.78%）。縮めても精度はほとんど落ちない
- **この Mac では whisper.cpp（Metal）より 2.4〜4 倍遅い**（5 秒未満 1.26 秒 対 0.53 秒、28 秒近くで 3.3 秒 対 0.87 秒）
- **プロンプトを入れると壊れる**。Koe の基本プロンプトでも開発者パックでも、CER が 31〜37% に上がり、空の答えが出て、遅くなる（pack で 5 秒未満 3.1 秒）。用語は 27/60 で whisper.cpp（28/60）並みになるが、この精度では使えない。WhisperKit の prompt tokens（prefill）の扱いの問題か、渡し方（WhisperKit の CLI の `--prompt` と同じく、トークン化して特殊トークンを除く）の問題かは切り分けていない
- 常駐メモリ 139 MB はヘルパーのプロセスだけの値で、Core ML のモデルの重みは数えられていない（比べられない）
- **koe-ios への意味**: WhisperKit で turbo を使うなら、精度は 626 MB でも十分。ただし Koe の強み（開発者パックのプロンプトで用語を当てる）はそのままでは使えず、自動置換だけになる。iOS で用語を効かせるなら、プロンプトの扱いの切り分けが先。iPhone 15 での速さはこの測定ではわからない

### 推奨

Mac の既定は whisper-turbo-metal のまま（変わらない）。WhisperKit は Mac では採らない。koe-ios では、精度（626 MB で十分）は満たすが、プロンプトが使えないことを前提に考える。

## 測っていないもの

- MLX Whisper（測らないと決めた）
- iPhone 上での速さ（WhisperKit・SpeechAnalyzer・sherpa-onnx とも、Mac でしか測っていない）
- カフェの雑踏などオフィス以外の雑音（`--noise PCAFETER` で測れる）
- 実際の声。公開データだけで測るという #154 の決まりに従った。実際の声で測るかは maintainer の判断
