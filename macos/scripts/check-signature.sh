#!/usr/bin/env bash
# Checks how Koe.app (and its bundled whisper-server) is signed.
#   bash check-signature.sh build/Koe.app                 # not ad-hoc, verifies
#   bash check-signature.sh --developer-id build/Koe.app  # also: Developer ID of
#       $TEAM_ID, hardened runtime, timestamp, entitlements, and the designated
#       requirement anchored to Apple and the team
set -euo pipefail
devid=0
[ "${1:-}" = --developer-id ] && { devid=1; shift; }
APP="$1"
TEAM_ID="${TEAM_ID:-9RQ8WG6688}"
fail() { echo "error: $*" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || fail "$APP does not verify (codesign --verify --deep --strict)"
parts=("$APP")
[ -f "$APP/Contents/MacOS/whisper-server" ] && parts+=("$APP/Contents/MacOS/whisper-server")
for f in "${parts[@]}"; do
  info=$(codesign -dvv "$f" 2>&1)
  grep -q "Signature=adhoc" <<<"$info" && fail "$f is ad-hoc signed"
  [ "$devid" = 1 ] || continue
  grep -q "^TeamIdentifier=$TEAM_ID\$" <<<"$info" || fail "$f is not signed by team $TEAM_ID"
  grep -q "^Authority=Developer ID Application: " <<<"$info" || fail "$f is not signed with a Developer ID Application certificate"
  grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime" <<<"$info" || fail "$f is not signed with the hardened runtime"
  grep -q "^Timestamp=" <<<"$info" || fail "$f has no secure timestamp"
  codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$f" \
    || fail "$f does not satisfy: anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\""
done
dr=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
echo "designated: $dr"
if [ "$devid" = 1 ]; then
  grep -q 'identifier "io.github.chaspy.koe"' <<<"$dr" || fail "designated requirement does not name io.github.chaspy.koe"
  grep -q 'anchor apple generic' <<<"$dr" || fail "designated requirement is not anchored to Apple"
  grep -Eq "certificate leaf\[subject\.OU\] = \"?$TEAM_ID\"?" <<<"$dr" || fail "designated requirement does not pin team $TEAM_ID"
  ents=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
  grep -q "com.apple.security.device.audio-input" <<<"$ents" || fail "$APP lacks the microphone entitlement (com.apple.security.device.audio-input)"
fi
echo "ok: $APP"
