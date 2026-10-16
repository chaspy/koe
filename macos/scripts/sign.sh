#!/usr/bin/env bash
# Signs Koe.app (and the bundled whisper-server) with the fixed "Koe Code
# Signing" identity, so the designated requirement is the same for every
# build and macOS keeps the Accessibility permission across updates.
#   SIGN_REQUIRED=1 bash scripts/sign.sh build/Koe.app   # release builds: never ad-hoc
# Without the identity (another developer's Mac) a dev build falls back to
# ad-hoc signing with a warning; set it up with scripts/signing-setup.sh.
set -euo pipefail
APP="$1"
NAME="${SIGN_IDENTITY:-Koe Code Signing}"
here=$(cd "$(dirname "$0")" && pwd)
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
if [ -f "$APP/Contents/MacOS/whisper-server" ]; then
  codesign --force "${SIGN[@]}" -i io.github.chaspy.koe.whisper-server "$APP/Contents/MacOS/whisper-server"
fi
codesign --force "${SIGN[@]}" "$APP"
if [ "${SIGN_REQUIRED:-0}" = 1 ]; then
  for f in "$APP" "$APP/Contents/MacOS/whisper-server"; do
    [ -e "$f" ] || continue
    if codesign -dv "$f" 2>&1 | grep -q "Signature=adhoc"; then echo "error: $f is ad-hoc signed" >&2; exit 1; fi
  done
fi
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated: /p'
