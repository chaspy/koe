# macOS code signing and notarization

## Why
macOS ties the Accessibility (and Microphone) permission to the app's code signature, through its *designated requirement*. With ad-hoc signing (`codesign -s -`) the signature changes with every build, so after each update the permission stays attached to the old binary: System Settings still shows Koe as allowed, but `AXIsProcessTrusted()` is false and ⌘V is silently dropped. Every build must therefore be signed by the same signer.

## Releases: Apple Developer ID (from the release after 0.8.0)
Release builds (`make dist`, `make notarize`, `scripts/release/release.sh`) are signed with the maintainer's **Developer ID Application** certificate, team `9RQ8WG6688`, and notarized by Apple. The designated requirement is anchored to Apple and the team, not to one certificate, so it survives certificate renewals:

```
designated => identifier "io.github.chaspy.koe" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "9RQ8WG6688"
```

How it is signed (`macos/scripts/sign.sh` with `SIGN_IDENTITY="Developer ID Application"`):
- The identity is looked up in the keychain by the team ID (`macos/scripts/developer-id.sh`), so the certificate holder's name is never written in the repository. With several matching identities, set `SIGN_IDENTITY` to the full name of one.
- Both `Koe.app` and the bundled `whisper-server` (identifier `io.github.chaspy.koe.whisper-server`) are signed with `--options runtime --timestamp` (hardened runtime, secure timestamp).
- Koe.app gets `macos/Koe.entitlements`, which holds only what the hardened runtime would otherwise block: `com.apple.security.device.audio-input` (recording) and `com.apple.security.automation.apple-events` (reading iTerm's screen for the opt-in `measureVisible`). whisper-server needs none.
- `macos/scripts/check-signature.sh --developer-id` then checks: not ad-hoc, `codesign --verify --deep --strict`, team ID, Developer ID authority, hardened runtime, timestamp, the microphone entitlement, and that the designated requirement is `anchor apple generic and certificate leaf[subject.OU] = "9RQ8WG6688"` (also verified with `codesign --verify -R=…`). A Developer ID build never falls back to another identity.

Notarization (`make notarize`, or step 5 of the release script, through `macos/scripts/notarize.sh`): checks the app in the dmg, signs the dmg with the same identity, `xcrun notarytool submit --keychain-profile koe --wait`, `xcrun stapler staple`, `stapler validate` and `spctl -a -vvv -t install`. On a rejection it prints the notarytool log. `scripts/release/release.sh --no-notarize` skips this step (Developer ID signature only; the release notes say so).

### Set up a Mac for releases (once)
1. Install the Developer ID Application certificate with its private key in the login keychain (Xcode → Settings → Accounts → Manage Certificates, or import the `.p12`). `security find-identity -v -p codesigning` should list `Developer ID Application: … (9RQ8WG6688)`. The first `codesign` may ask to allow access to the key: choose "Always Allow".
2. Store the notarization credentials as the keychain profile `koe` (an app-specific password of the Apple Account, or an App Store Connect API key):
   ```sh
   xcrun notarytool store-credentials koe --apple-id <apple account> --team-id 9RQ8WG6688
   xcrun notarytool history --keychain-profile koe     # works = ready
   ```
Nothing of this goes into the repository.

### Moving from the self-signed certificate (0.8.0 and earlier)
Up to 0.8.0, releases were signed with the self-signed "Koe Code Signing" certificate. The Developer ID signature has a different designated requirement, so **the first update from 0.8.0 or earlier needs the Accessibility permission once more**: macOS keeps showing Koe as allowed but no longer trusts it. Remove Koe in System Settings → Privacy & Security → Accessibility and add it again (the Microphone permission is asked for again too). Koe detects this: when `AXIsProcessTrusted()` is false it does not paste, records `outcome=no_accessibility`, keeps the text on the clipboard and shows how to fix it (with `permissionGuide` on, the floating guide). Later updates keep the permission, also across certificate renewals. The release notes of that version say so (CHANGELOG).

## Development builds: "Koe Code Signing" (self-signed)
`make build` / `make install` sign with the self-signed "Koe Code Signing" certificate by default, so a developer's own builds keep their permissions too without an Apple account. They have no hardened runtime and are not for distribution. `make dist SIGN_IDENTITY="Koe Code Signing"` makes a self-signed dmg for testing.

- RSA 2048, valid 10 years, Extended Key Usage = codeSigning. It lives in its own keychain, `~/Library/Keychains/koe-signing.keychain-db`, whose random password is stored in the login keychain (generic password, service `koe-signing-keychain`); the key's partition list allows codesign, so builds sign without a dialog.
- Create it once per Mac: `bash macos/scripts/signing-setup.sh` (no-op if it exists; prints the SHA-1). To use the same one on another Mac, export it as a p12 and run `bash macos/scripts/signing-setup.sh --import <file.p12>`.
- Without it, a dev build falls back to ad-hoc signing with a warning (and macOS asks for Accessibility again after each build).

Installing a dev build over a Developer ID release (or the other way round) changes the signer, so the Accessibility permission has to be granted again.

## Check a build
```sh
bash macos/scripts/check-signature.sh --developer-id macos/build/Koe.app   # release build
codesign -d -r- macos/build/Koe.app            # designated requirement
codesign -dvv macos/build/Koe.app 2>&1 | grep -E 'Authority|TeamIdentifier|flags'
spctl -a -vvv -t install macos/build/Koe-<version>.dmg   # notarized dmg: "source=Notarized Developer ID"
```
