# Koe の使い方

Koe は、キーを押して話すと文字にして貼り付ける、Mac のメニューバーアプリです。
音声も文字も自分の Mac の中で処理し、既定では外に送りません。メニューバーの吹き出しのアイコンが Koe です。
何を手元に残し、何がいつ外に出るかは [Koe が扱うデータ](data-ja.md) にまとめています。

Optional LLM cleanup and the improvement loop can send text to the configured service; see [data handling](data-ja.md).

## 基本: 押している間だけ話す

1. 文字を入れたい欄（ターミナル、Slack、ブラウザなど）にカーソルを置く
2. **右⌘を押しながら話す**（「ポン」と鳴ったら録音中）
3. **離す** → 文字になって、その欄に貼り付きます
   - ターミナル（iTerm・Terminal・Ghostty など）では、貼り付けた後に Enter まで送ります
   - それ以外のアプリでは貼るだけで、送信はしません

押している間にほかのキーを押すと、録音を取り消します（⌘C などのショートカットがそのまま使えるように）。

## 長く話すとき: ロック録音

1on1 のメモなど、キーを押し続けられないとき用です。

- **右⌘を素早く 2 回押す**（「ポ・ポン↑」と鳴る）か、メニューの「ロック録音を始める」
- キーを押さずに話し続けます。キーボードやマウスを使っても止まりません
- **もう 1 回押す**（「ポン↑・ポン」と鳴る）と終わり、話した内容が `書類/Koe/日時.txt` に保存されて開きます。クリップボードにも入ります

## メニューで変えられること

| 項目 | 内容 |
|---|---|
| 押して話すキー | 右⌘ / 右⌥ / 右⌃ / fn。US 配列で ⌘+Space などと重なるときに変える |
| 押し方 | 「押している間だけ録音」（既定）か「押すたびに開始・終了（トグル）」。トグルでは、短く押すと録音が始まり、もう一度押すと終わって貼り付けます |
| 区切りごとに改行する（ターミナル以外。Docs 向け） | `lineBreaks`: off by default. Click to enable line breaks in non-terminal apps. |
| 用語パック | よく使う語を正しい表記で聞き取らせる辞書。開発用（developer）は最初から入っています |
| マイク | Select a fixed input or automatic mode; set the preferred backup with `fallbackMicName` (see below). |
| 使うほど賢くする（改善ループ） | `improveEnabled`: off by default. Click and confirm the destination to enable glossary learning; the default command is `claude -p --model sonnet`. |
| 最近の文字起こし（クリックでコピー） | 貼り付けに失敗したときに、ここから取り出せます |
| 履歴を残す期間 | 録音と文字起こしの履歴（`~/Library/Application Support/Koe/history`）は、既定で録音 14 日・文字 30 日残して消します（全体が 1GB を超えたら古い録音から）。7 / 14 / 30 / 90 日 / ずっと から選べます。ロック録音の `書類/Koe` は消しません |

## うまくいかないとき

- **Permissions / no paste:** allow Microphone and Accessibility in System Settings → Privacy & Security. If Accessibility stopped working after an update, remove and re-add Koe ([why](notes/signing.md#changing-the-certificate)). Keep the original app focused; if the target changes, Koe leaves the text on the clipboard instead. Use ⌘V or 「最近の文字起こし（クリックでコピー）」 to recover it.
- **The first word is cut off:** turn on 「マイクを常時待機（頭切れ防止）」 (`warmMic`, default `true`), which keeps 0.5 s before the key press. Recording continues for 0.25 s after release.
- **Muted mic:** 「マイク」 selects a fixed input or 「自動（既定のマイク…）」. Automatic mode uses another working mic during hardware mute (`fallbackMic`, default `true`). To prefer a backup, quit Koe, run `defaults write io.github.chaspy.koe fallbackMicName -string "Your backup mic name"`, and relaunch. A fixed mic does not use automatic fallback.

- **声が途切れる・聞き取られない**: マイクを口元に近づけるか、システム設定 → サウンド → 入力 で入力音量を上げる（声が小さいと Koe が知らせます）
- **貼られなかった**: メニューの「最近の文字起こし（クリックでコピー）」から取り出せます
- **遅い・動かない・おかしい**: メニューの **「診断情報を書き出す（不具合を送る用）」** を押すと、デスクトップに zip ができます。それを作者に送ってください。版・機種・設定（秘密の値は伏せる）・動作の記録と速さが入ります。文字起こしの本文・録音・辞書の中身は入りません

## 更新

新しい版が出ると、メニューに「新しい版 vX があります」と出ます。押すと入れ替わって起動し直します。使い終わって落ち着いたとき（話し終えて 30 秒ほどたったとき）に 1 回だけ「今すぐ更新 / あとで」とも聞きます。「あとで」なら次の起動か 24 時間後まで聞きません。勝手に入れ替わることはありません。
