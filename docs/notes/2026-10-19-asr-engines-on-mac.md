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
2. 用語の 60 文の WAV（キャッシュの `asr-terms/000.wav`〜`059.wav`。`asr_bench.py` を 1 回動かすとできる。中身は `term_items(packs/developer.txt)` の順）を、モジュールごと（引数 `speech` / `dictation`）に、次の 3 通りで 1 行ずつ渡す。1 行は「WAV のパス」、または「WAV のパス + タブ + 手がかりをタブ区切り」
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

## 測っていないもの

- 予備の候補（ReazonSpeech、Moonshine-tiny-ja、Qwen3-ASR、WhisperKit、MLX Whisper）
- 雑音を足した条件（VAD・audio_ctx の測定で使ったもの）
- 実際の声。公開データだけで測るという #154 の決まりに従った。実際の声で測るかは maintainer の判断
