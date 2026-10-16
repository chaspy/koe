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
