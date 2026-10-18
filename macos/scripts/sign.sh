#!/usr/bin/env bash
# Signs Koe.app (and the bundled whisper-server) so the designated requirement
# is the same for every build and macOS keeps the Accessibility permission
# across updates. Two identities (docs/notes/signing.md):
#   SIGN_IDENTITY="Developer ID Application"  # releases (make dist): Apple
#       Developer ID of team $TEAM_ID, hardened runtime, secure timestamp and
#       macos/Koe.entitlements; checked with check-signature.sh --developer-id
#   SIGN_IDENTITY="Koe Code Signing"          # development builds (default):
#       the self-signed certificate made by scripts/signing-setup.sh
#   SIGN_REQUIRED=1 bash scripts/sign.sh build/Koe.app   # never ad-hoc
# Without the self-signed identity (another developer's Mac) a dev build falls
# back to ad-hoc signing with a warning. A Developer ID build never falls back.
set -euo pipefail
APP="$1"
NAME="${SIGN_IDENTITY:-Koe Code Signing}"
here=$(cd "$(dirname "$0")" && pwd)
ENTITLEMENTS="${ENTITLEMENTS:-$here/../Koe.entitlements}"
devid=0
case "$NAME" in
  "Developer ID Application"*)
    devid=1
    hash=$(SIGN_IDENTITY="$NAME" bash "$here/developer-id.sh")
    SIGN=(--sign "$hash" --options runtime --timestamp)
    ;;
  *)
    KC=$(SIGN_IDENTITY="$NAME" bash "$here/signing-unlock.sh")
    if [ -n "$KC" ]; then
      SIGN=(--keychain "$KC" --sign "$NAME")
    elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
      SIGN=(--sign "$NAME")
    elif [ "${SIGN_REQUIRED:-0}" = 1 ]; then
      echo "error: signing identity \"$NAME\" not found; release builds are never ad-hoc signed (see docs/notes/signing.md)" >&2
      exit 1
    else
      echo "warning: \"$NAME\" not found; ad-hoc signing (macOS will ask for Accessibility again after each build). Run macos/scripts/signing-setup.sh" >&2
      SIGN=(--sign -)
    fi
    ;;
esac
if [ -f "$APP/Contents/MacOS/whisper-server" ]; then
  codesign --force "${SIGN[@]}" -i io.github.chaspy.koe.whisper-server "$APP/Contents/MacOS/whisper-server"
fi
if [ "$devid" = 1 ]; then
  codesign --force "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
  bash "$here/check-signature.sh" --developer-id "$APP"
  exit 0
fi
codesign --force "${SIGN[@]}" "$APP"
if [ "${SIGN_REQUIRED:-0}" = 1 ]; then
  bash "$here/check-signature.sh" "$APP"
else
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated: /p'
fi
