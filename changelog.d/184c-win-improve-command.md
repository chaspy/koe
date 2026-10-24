### Windows
- Fixed: 改善ループのコマンド（既定 claude）を、よくあるインストール先（%USERPROFILE%\.local\bin・%APPDATA%\npm・%USERPROFILE%\.claude\local）と PATH から探してフルパスで動かします（Koe の起動後に入れた Claude Code も見つかります）。見つからないとき（終了コード 9009）は探し直します。3 回続けて失敗したら、1 日 1 回まで「もう一度試す」付きで知らせます（録音中は出しません）。koe.log には終了コードと見つかった場所の種類だけを書きます。
