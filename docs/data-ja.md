# Koe が扱うデータ

Koe は、声を自分のパソコンの中で文字にします。文字起こしをするのは、Koe が自分で起動する whisper-server です。この whisper-server は `127.0.0.1`（自分のパソコンの中だけ）で待ち受けるので、録音を外に送ることはありません。Windows で `config.json` の `engine` を `"parakeet"`（試験中）にしたときは、Koe 自身のプロセスの中で Parakeet-ja が文字にします（待ち受けるポートもありません）。
**既定の設定では、録音も文字も外に送りません。** 外に出るのは、更新の確認などの通信（下の 2）と、自分でオンにした機能（下の 3）だけです。

このページは、ソースコード（macOS は `macos/Sources/Koe/`、Windows は `windows/`）に書かれている動作をまとめたものです。

## 1. 手元に残るもの

### macOS

| もの | 場所 | 中身 | 消えるタイミング |
|---|---|---|---|
| 履歴（録音） | `~/Library/Application Support/Koe/history/<日付>/<id>.wav` | 話した録音 | 既定は 14 日で消す |
| 履歴（文字と記録） | 同じ場所の `<id>.json` | 文字起こし・貼った文・貼った先のアプリ・マイク名・速さなど | 録音の約 2 倍の期間（既定 30 日）で消す |
| 比較用の録音 | 同じ場所の `<id>.alt.wav` | 使わなかった側のマイクの録音。設定 `saveAllMics` をオンにしたときだけ（既定はオフ） | 録音と同じ |
| 動作の記録 | `~/Library/Application Support/Koe/events.jsonl` | 押した・貼った・失敗した理由・かかった時間など | 消さない |
| 個人の辞書 | `~/Library/Application Support/Koe/glossary.txt` | 自分で足した語と、改善ループが足した語 | 消さない |
| 用語パック・組織の辞書 | `~/Library/Application Support/Koe/packs/`、`org_glossary.txt`、`org_glossary.cache.txt` | 取り込んだ語の一覧 | 消さない |
| ロック録音の文字 | `~/Documents/Koe/<日時>.txt`（書類/Koe） | ロック録音で話した内容 | 消さない（履歴を消すときも対象外） |
| 受け取る AI 向けのメモ | `~/.claude/koe-voice-glossary.md` と `koe-voice-glossary.full.md`（場所は設定 `receiverGlossaryPath` で変えられる）。`peopleSources` を設定したときは、同じ場所に `koe-people.md`（社員全員の ID・本名と、分かった呼び方・化けた形。分からない名前に出会ったときだけ引く） | 辞書の語と、よく化ける形の一覧。話した文は入らない | 辞書が変わるたびに書き直す。`~/.claude` が無ければ書かない |
| 改善ループの作業ファイル | `~/Library/Application Support/Koe/glossary_candidates.json`、`improve_last_response.txt`、`people_known.json` | 辞書に足す語の候補、AI の直近の返答、改善ループで分かった人の呼び方と化けた形。「使うほど賢くする（改善ループ）」をオンにしたときだけ作られる | 消さない |
| 社員名簿（macOS のみ） | `~/Library/Application Support/Koe/people/` | `peopleSources` から取り込んだ ID と本名の一覧。設定したときだけ | 消さない（1 日 1 回取り直す） |
| 文字起こし用のモデル | `~/Library/Application Support/Koe/models/` | whisper のモデル | 消さない |
| whisper-server のログ | `~/Library/Caches/koe/whisper-server.log` | 起動と処理時間の記録 | whisper-server を起動するたびに作り直す |

**履歴を残す期間**: メニュー →「履歴を残す期間」で、7 / 14（既定）/ 30 / 90 日 / ずっと から選べます。文字と記録は、録音の約 2 倍の期間残ります。history 全体が 1GB を超えたときは、古い日の録音から消します。消す処理は、起動したときと 1 日 1 回、裏で動きます。直近 1 日のうちに変わったファイルは消しません。
メニュー →「録音と結果を保存（評価用）」をオフにすると、履歴は残りません（録音は文字にしたあと消します）。

**予備のマイクの録音も残す（既定はオフ）**: 比べるために予備のマイクの録音も残したいときは、Koe を終了して `defaults write io.github.chaspy.koe saveAllMics -bool true` を実行し、起動し直します。履歴の保存（設定 `saveHistory`、既定はオン）がオンのときだけ残ります。

**iTerm の画面を読む（macOS、既定はオフ）**: `defaults write io.github.chaspy.koe measureVisible -bool true` でオンにしたときだけ、iTerm に貼ったあと最大 10 秒、iTerm の今のセッションの画面の文字（AppleScript の contents）を読み、貼った文の末尾が出るまでの時間を測ります。読んだ画面の中身と貼った文は比べるのにだけ使い、どこにも書きません（履歴と動作の記録には `visible`・`visible_ms` などの数字と結果だけが残ります）。オンにして初めて測るときに macOS がオートメーション（Koe が iTerm を操作する）の許可を求めます。オフの間は画面を読まず、許可も聞きません。許可しなくても貼り付けはそのまま使えます（測れなかった、と記録するだけ）。止めるには `defaults write io.github.chaspy.koe measureVisible -bool false`。

### Windows

| もの | 場所 | 中身 | 消えるタイミング |
|---|---|---|---|
| 履歴（録音と文字） | `%LOCALAPPDATA%\Koe\history\<日付>\<id>.wav` と `<id>.json` | macOS と同じ | macOS と同じ規則（`historyKeepDays`、既定 14 日・文字 30 日・1GB 上限。トレイ →「履歴を残す期間」で変えられる） |
| 動作の記録 | `%LOCALAPPDATA%\Koe\koe.log`（と 1 つ前の `koe.log.1`） | 押した・貼った・失敗した理由・かかった時間など（話した文は書かない） | 5MB を超えたら `koe.log.1` に回し、その前のものは消える |
| whisper-server のログ | `%LOCALAPPDATA%\Koe\whisper-server.log`（GPU 版は `whisper-server-vulkan.log`） | 起動と処理時間の記録 | 起動するたびに作り直す |
| 更新の記録 | `%LOCALAPPDATA%\Koe\update.log` | 更新の確認と入れ替えの記録 | — |
| 文字起こし用のモデル | `%LOCALAPPDATA%\Koe\models\` | whisper のモデル。`config.json` の `engine` を `"parakeet"` にしたときは、Parakeet-ja のモデル（`models\sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8\` に `model.int8.onnx` と `tokens.txt`、約 630MB。取得中は同じ場所に `.tar.bz2` と `.part` が一時的にできる） | 消さない |
| 設定・個人の辞書・用語パック | `%APPDATA%\Koe\config.json`、`glossary.txt`、`packs\` | 設定と語の一覧 | 消さない |
| 受け取る AI 向けのメモ | `%USERPROFILE%\.claude\koe-voice-glossary.md` と `.full.md` | macOS と同じ | `%USERPROFILE%\.claude` が無ければ書かない |

履歴を残さないようにするには、`config.json` の `saveHistory` を `false` にします。Windows 版には、ロック録音・改善ループ・LLM 整形・組織の辞書はありません。

## 2. 外に出る通信（録音も文字も送らない）

どの通信も、取ってくるだけです。録音・文字・辞書の中身は送りません。

| 通信 | 送り先 | いつ | 送るもの |
|---|---|---|---|
| 更新の確認 | `https://github.com/<repo>/releases/latest` に `HEAD`（転送先の URL から版を読む。転送先は開かない） | 起動したとき、1 日 1 回、メニューを開いたとき（前の確認から 1 分以上たっていれば） | ふつうの HTTP の要求だけ（Windows は User-Agent を `Koe-windows/<版>` にする）。GitHub の API は使わない |
| 新しい版の変更点 | `https://raw.githubusercontent.com/<repo>/v<版>/CHANGELOG.md` | 新しい版が見つかったとき | 同上 |
| Windows 版があるかの確認（Windows のみ） | `https://github.com/<repo>/releases/download/v<版>/Koe-<版>-windows-x64.zip` に `HEAD` | 新しい版が見つかったとき | 同上 |
| 更新のダウンロード | macOS は `…/releases/download/v<版>/Koe-<版>.dmg`、Windows は上の zip（GitHub の配布用サーバーへ転送される） | 「今すぐ更新」かメニューの「新しい版 vX があります」を押したときだけ | 同上 |
| 初回のモデル取得 | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<モデル>`（macOS は `ggml-large-v3-turbo.bin`、Windows は `ggml-small-q5_1.bin`。設定 `modelURL` で変えられる） | モデルが手元に無いとき | 同上 |
| Parakeet-ja のモデル取得（Windows のみ） | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8.tar.bz2`（GitHub の配布用サーバーへ転送される） | `config.json` の `engine` を `"parakeet"` にして、モデルが手元に無いとき | 同上 |
| 共有の用語パック | `packSources` に書いた取り込み元。`gh:owner/repo/path` は gh CLI（`gh api …/contents/…`）で取る。macOS は `https://…` の URL も使える（Windows は `gh:` だけ） | `packSources` を設定したときだけ。1 日 1 回 | gh CLI の場合は、gh にログインしているアカウントで要求する |
| 組織の辞書（macOS のみ） | `orgGlossary` に書いた `http(s)://` の URL | `orgGlossary` に URL を設定したときだけ。1 日 1 回 | ふつうの HTTP の要求だけ |
| 社員名簿（macOS のみ） | `peopleSources` に書いた取り込み元（`gh:owner/repo/path` か `https://…`。用語パックと同じ取り方） | `peopleSources` を設定したときだけ。1 日 1 回 | 用語パックと同じ |

`<repo>` は既定では公開版の `chaspy/koe` です（設定 `updateRepo` で変えられます）。更新の確認を止めるには、設定 `updateCheck` を `false` にします（macOS は defaults、Windows は `config.json`）。Windows はその状態でもメニューの「更新を確認」を押せば手で確認できます。macOS は `updateCheck` をオンに戻してから確認してください。

## 3. 自分でオンにしたときだけ外に出るもの（macOS のみ）

### 「使うほど賢くする（改善ループ）」— 既定はオフ

メニューの「使うほど賢くする（改善ループ）」（設定 `improveEnabled`）を押し、送り先を確認するとオンになります。オフのまま 30 回話すと、メニューバーの下に「有効にする / 内容を見る / 今はしない」の提案が出ますが、提案から押した場合も同じ確認を出し、黙ってオンにはしません。「改善ループで送る内容を見る…」は、次に送る内容をこの Mac の中で組み立てて見せるだけで、何も送りません。

オンにすると、新しい発話が 30 件たまるごと（設定 `improveBatch`）、録音していないときに、次の内容を AI に送ります。AI はそれを読んで、誤変換された語を見つけ、伝わったかどうかを判定します。

- 送るもの: 発話の文字起こし（1 回に最大 60 件。判定だけやり直すときは 30 件）。Claude Code のセッション記録（`~/.claude/projects`）に同じ文があれば、その発話の「実際に送った文」（300 文字まで）、「Claude の返答」（400 文字まで）、「次の発話」（200 文字まで）も送る。あわせて、辞書にもうある語（最大 400 語）も送る。`peopleSources` を設定しているときは、**社員名簿の全員分（ID と本名）も毎回送る**（化けた名前が誰のことかを AI に当てさせるため）
- 送らないもの: 録音、ロック録音の内容（相手の声が入りうるため）、失敗して捨てた発話（声が無い・雑音と判定した、など）
- 送り先:
  - 既定は、コマンド `claude -p --model sonnet`（設定 `improveCommand`）。標準入力で渡すので、自分の Claude Code が使っているサービスに送られます
  - API 型（`improveProvider` = `api`）にすると、`improveEndpoint` に設定した OpenAI 互換の送り先に送ります（`improveAPIKey` か `improveTokenCommand` で認証）
- オンにするときは、送るものと送り先を示して確認を求めます（社員名簿を送る場合はその人数も示します）
- 人の名前は、「〜さん」などの敬称が付き、前後に Slack・レビューなどの人とのやりとりがあり、AI が確かだと答えたときだけ辞書に足します。わざと言ったあだ名は本名に書き換えません（名字が同じ読みの別の漢字に化けたもの、例: 山舌さん → 山下さん は直します。ひらがな・カタカナ・英字だけの形と、その人について分かっている呼び方は、本人が直したとき以外は本名にしません）。名簿の名前は whisper の初期プロンプトにも LLM 整形にも使いません。1 回確かに見つけたときは、AI が出した「同じ人が化けそうな近い読みの形」（最大 5 つ）も同じ条件で、敬称が続くときだけ置き換わる別名として足します

### LLM 整形 — 既定はオフ

メニューの「LLM で整形（qwen2.5:7b）」（設定 `llmEnabled`。メニューの名前は設定 `llmModel` に合わせて変わります）を押すとオンになります。

設定 `llmEnabled` をオンにすると、貼る前に、文字起こしを `llmEndpoint` の OpenAI 互換の送り先に送って整えます。送るのは、文字起こしと、整形の指示と、辞書の語の一覧です。
送り先の既定は `http://localhost:11434/v1`（自分のパソコンの中の Ollama）です。ほかの送り先を設定した場合だけ、そこに文字起こしが届きます。オンの間は、モデルを読み込んだままにしておくため、4 分ごとに短い要求（「ok」の 1 語）を送ります。

## 4. 診断情報の zip

メニューの「診断情報を書き出す（不具合を送る用）」（Windows: 「診断情報を書き出す（送る用）」）を押すと、デスクトップに `Koe-diagnostics-<日時>.zip` ができます。**自動では送りません。** 送るかどうかは自分で決めます。

| | macOS | Windows |
|---|---|---|
| 入るもの | 版・macOS の版・機種・CPU・メモリ・負荷、モデルの場所と大きさ、マイクの名前、設定（下を参照）、履歴の保存期間と大きさ、辞書の語数と社員名簿の人数（名簿の中身は入れない）、直近 300 回の速さと結果（数字・貼った先のアプリ・貼れたかどうか・伝わったかの判定）、`events.jsonl` の直近 3000 行（語や本文が入りうる欄は伏せる）、`whisper-server.log` の末尾 500 行 | 版・Windows の版・CPU・メモリ・GPU の名前、モデルの場所、設定（下を参照）、履歴の保存期間と大きさ、`koe.log` の末尾 2000 行、`whisper-server.log`（と GPU 版のログ）の末尾 500 行、`update.log` の末尾 1000 行。どのログも、本文が入りうる欄（`text=` `raw=` `pasted=` `prompt=` など）は伏せる |
| 設定の扱い | `key` `token` `secret` `password` `auth` を含む設定は `***` にする。プロンプト・改善ループのコマンド・辞書や社員名簿（`peopleSources`）の場所など、語や本文が入りうる設定は文字数だけ書く | macOS と同じ（`hotkey` `menuMaskKey` は秘密として扱わない） |
| 入らないもの | 録音、文字起こしの本文、辞書の中身 | 同じ |

モデルの場所などのファイルパスには、パソコンのユーザー名が含まれることがあります。
