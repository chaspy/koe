# macOS: optional automatic restart

「予期せず終了したら自動で再起動」は既定でオフです。オンにする操作は
Koe のメニューだけです。「ログイン時に起動」とは独立しています。

## 置かれるもの・解除

- オンにすると `~/Library/LaunchAgents/io.github.chaspy.koe.restart.plist` を書き、
  `launchctl bootstrap gui/<uid> <plist>` で本人の GUI セッションに登録します。
- plist は Koe 自身の `--auto-restart-agent` 監視モードを指します。
  `KeepAlive = { SuccessfulExit = false }`、`ThrottleInterval = 30`、Aqua セッション限定です。
  既存のアプリやモデル、署名、ログイン項目は書き換えません。
- 起動時に `~/Library/Application Support/Koe/restart-session.json` に
  PID・実行パス・カーネル起動時刻・終了要求の有無を記録します。
  本文やウィンドウ名は記録せず、診断 ZIP にも追加しません。
- オフにすると先に plist を削除し、`launchctl bootout gui/<uid>/io.github.chaspy.koe.restart`
  で監視ジョブを外します。Koe 本体は LaunchServices で起動されるため終了しません。
  session ファイルは次回起動で上書きするローカル状態として残り、自動起動の効力はありません。
- bootstrap に失敗した場合は plist を削除してオフに戻します。bootout が失敗した場合も
  plist は削除済みで、監視側がその削除を見て成功終了します。設定失敗は画面に表示します。
- アンインストール前にはメニューでオフにしてください。手動で片付ける場合は上記 plist の
  削除と本人の GUI セッションの bootout を行います。アプリを移動したらオフ→オンで登録を更新します。

## 終了と再開の判定

監視中のアプリが生きていれば何もしません。通常の終了要求（メニュー・Apple Event・
ログアウトなど）は、終了待ちに入る前に session に記録します。終了後にその記録があれば
監視側は exit 0 で終了し、launchd は再起動しません。強制終了（SIGKILL）は終了要求を記録できないため異常終了として扱います。
終了意図の保存に失敗した場合は plist を削除して監視ジョブを解除し、自動再起動をオフにします。
解除にも失敗した場合は通常の終了を中止し、エラーを表示します。次の終了操作で再試行できます。
終了要求がなく PID の同一性が失われた
場合だけ exit 1 とし、launchd が監視を再起動します。次の監視が `/usr/bin/open -g <Koe.app>`
でアプリを開きます。30 秒以内に新しい session が現れない場合も失敗終了し、再試行を抑制します。

利用者が再び Koe を開くと、既にオンの監視ジョブだけを kickstart します。
起動時に plist を新設したり bootstrap したりすることはありません。前回が通常終了なら
次のログインでもこの監視は Koe を開きません（別の「ログイン時に起動」の設定は従来どおりです）。
前回が異常終了なら次の GUI ログイン時にも再開できます。silent exit 自体の原因は未特定です。

## 検証

`nice -n 15 make -C macos test T=auto-restart` は全判定の組合せ、plist の内容、
登録・解除の引数、登録失敗時の復元、終了要求の保存を確認します。
plist と session は UUID 付き一時ディレクトリにだけ書き、実行処理は注入した偽物です。
本物の `~/Library/LaunchAgents`、launchctl、open、利用者の Koe には触りません。

実際のメニュー・launchd による再起動は、利用者のアプリを使わない専用 macOS アカウントで
オン→異常終了→再開、終了→停止、手動起動→監視再開、オフ→plist/ジョブ削除を確認してください。

`python3 macos/Tests/auto-restart/test_integration.py` は手動実行の結合テストです。
一時ディレクトリのダミーアプリと UUID 付き `io.github.chaspy.koe.restart.test.*` だけを
本人の GUI セッションに登録し、異常終了後の再開・通常終了・保存失敗時の解除を確認します。
終了時は成功・失敗にかかわらずテスト用ジョブを bootout し、plist とダミーアプリを削除します。
製品のラベルや使用中の Koe、本物の LaunchAgents ディレクトリは操作しません。
