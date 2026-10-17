# macOS code signing (Koe Code Signing)

## Why
macOS ties the Accessibility (and Microphone) permission to the app's code signature. With ad-hoc signing (`codesign -s -`) the signature changes with every build, so after each update the permission stays attached to the old binary: System Settings still shows Koe as allowed, but `AXIsProcessTrusted()` is false and ⌘V is silently dropped. Signing every build with the same certificate keeps the designated requirement fixed:

```
designated => identifier "io.github.chaspy.koe" and certificate leaf = H"<SHA-1 of the certificate>"
```

so the permission survives updates. The bundled whisper-server is signed with the same certificate (identifier `io.github.chaspy.koe.whisper-server`).

## The certificate
- Self-signed code-signing certificate "Koe Code Signing" (RSA 2048, valid 10 years, Extended Key Usage = codeSigning).
- It lives in its own keychain, `~/Library/Keychains/koe-signing.keychain-db`. That keychain's random password is stored in the login keychain (generic password, service `koe-signing-keychain`), and the key's partition list allows codesign. So builds unlock it and sign without any dialog. A key imported into the login keychain itself would need the login password once to allow codesign.
- The private key is never in the repository.

## 前提ツール

- Xcode Command Line Tools: `xcode-select --install`（Swift、make、codesign）。
- CMake: `brew install cmake`（同梱する whisper-server のビルド用）。
- OpenSSL: macOS 付属のもの、または `brew install openssl@3`。
  Homebrew 版を使う場合は `export PATH="$(brew --prefix openssl@3)/bin:$PATH"` で選択できます。

OpenSSL 3 では PKCS#12 の既定の暗号方式を `security import` が読み込めず、
`MAC verification failed during PKCS12 import (wrong password?)` になるため、
セットアップは `-legacy` を付けて出力します。OpenSSL 1.1 / LibreSSL では付けません。
import に失敗した場合は作成途中の keychain と login keychain 内のパスワード項目を削除し、
エラー終了します。原因を解消してからセットアップを再実行してください。

## Create it (once per Mac)
```sh
bash macos/scripts/signing-setup.sh        # no-op if it already exists; prints the SHA-1
```
`make build` / `make install` / `make dist` then sign through `macos/scripts/sign.sh`:
- `make dist` (release, used by the publish script) stops if the identity is missing and checks that nothing ended up ad-hoc signed.
- A dev build on a Mac without the identity falls back to ad-hoc with a warning.

Check a build:
```sh
codesign -d -r- macos/build/Koe.app      # same "certificate leaf" value every build
codesign -dv macos/build/Koe.app 2>&1 | grep Authority   # Authority=Koe Code Signing (never Signature=adhoc)
```

## Move it to another Mac
Use the same certificate everywhere, or users' permissions reset when the signer changes.

On the Mac that has it (export the identity as a password-protected p12; keep the file out of the repo and delete it after the transfer):
```sh
KC=~/Library/Keychains/koe-signing.keychain-db
security unlock-keychain -p "$(security find-generic-password -s koe-signing-keychain -a "$USER" -w)" "$KC"
security export -k "$KC" -t identities -f pkcs12 -P '<p12 password>' -o ~/Desktop/koe-signing.p12
```
On the other Mac:
```sh
bash macos/scripts/signing-setup.sh --import ~/Desktop/koe-signing.p12   # asks for the p12 password
rm ~/Desktop/koe-signing.p12
```
Check that `security find-certificate -c "Koe Code Signing" -Z ~/Library/Keychains/koe-signing.keychain-db` shows the same SHA-1 on both Macs.

## Changing the certificate
A different certificate (or going back to ad-hoc) changes the designated requirement, and every user has to grant Accessibility once more (remove Koe in System Settings → Privacy & Security → Accessibility and add it again). Koe detects this: when `AXIsProcessTrusted()` is false it does not paste, records `outcome=no_accessibility`, keeps the text on the clipboard, and shows how to fix it (at launch and on the first failed paste).

## 公開版 dmg の後にソース版を入れる場合

公開版とこの Mac で作成した証明書では designated requirement の `certificate leaf` が
異なります。設定画面では許可済みでも `AXIsProcessTrusted()` が false になり得ます。
`make install` はインストール先の既存アプリとビルドしたアプリの署名要件を比較し、
異なる場合は置き換える前に stderr に警告します（インストールは続行します）。

1. 公開版 Koe を終了し、証明書をセットアップしてソース版をビルドします。
2. 公開版が `/Applications/Koe.app` にある場合は `cd macos` の後に
   `make install INSTALL_DIR=/Applications` で同じ場所へインストールします。
   既定のインストール先は `~/Applications` なので、公開版の場所に合わせてください。
3. Koe を終了し、システム設定 → プライバシーとセキュリティ → アクセシビリティで
   Koe を一度削除し、今回インストールした Koe.app を追加して許可します。
4. マイクの許可も再付与します。マイクの設定画面では項目を削除できないため、
   ターミナルで `tccutil reset Microphone io.github.chaspy.koe` を実行し、
   Koe を起動して録音時に再度許可します。

同じ証明書を使い続ける次回以降の更新では、署名要件は維持されます。
