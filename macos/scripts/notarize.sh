#!/usr/bin/env bash
# Signs the release dmg with the Developer ID identity, has Apple notarize it,
# staples the ticket and checks it with Gatekeeper.
#   bash scripts/notarize.sh build/Koe-0.9.0.dmg
#   NOTARY_PROFILE  notarytool keychain profile (default: koe), made once with
#                   xcrun notarytool store-credentials koe ... (docs/notes/signing.md)
# The app inside must already be Developer ID signed (make dist does that).
set -euo pipefail
DMG="$1"
PROFILE="${NOTARY_PROFILE:-koe}"
here=$(cd "$(dirname "$0")" && pwd)
fail() { echo "error: $*" >&2; exit 1; }

# the app inside the dmg must already pass the Developer ID checks
mnt=$(mktemp -d)
trap 'hdiutil detach -quiet "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$DMG" >/dev/null
bash "$here/check-signature.sh" --developer-id "$mnt/Koe.app"
hdiutil detach -quiet "$mnt"

hash=$(SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}" bash "$here/developer-id.sh")
codesign --force --sign "$hash" --timestamp "$DMG"

# exits non-zero for a rejected submission too; the status decides
out=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json) || true
status=$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null || true)
id=$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null || true)
if [ "$status" != Accepted ]; then
  if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true; fi
  fail "notarization of $DMG: status \"$status\" (submission $id)"
fi
echo "notarized: submission $id"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t install "$DMG"
