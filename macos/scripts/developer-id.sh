#!/usr/bin/env bash
# Prints the SHA-1 of the "Developer ID Application" identity of team
# $TEAM_ID (default: Koe's team) in the user's keychains, or fails.
#   SIGN_IDENTITY  "Developer ID Application" (any name of that team) or the
#                  full name "Developer ID Application: <name> (<team>)"
# The certificate's name is never written to the repository; it is found by
# the team ID, which is part of every signature anyway.
set -euo pipefail
TEAM_ID="${TEAM_ID:-9RQ8WG6688}"
NAME="${SIGN_IDENTITY:-Developer ID Application}"
valid=$(security find-identity -v -p codesigning 2>/dev/null || true)
case "$NAME" in
  "Developer ID Application") matches=$(grep -E "\"Developer ID Application: .* \($TEAM_ID\)\"" <<<"$valid" || true) ;;
  "Developer ID Application: "*"($TEAM_ID)") matches=$(grep -F "\"$NAME\"" <<<"$valid" || true) ;;
  *) echo "error: \"$NAME\" is not a Developer ID Application identity of team $TEAM_ID" >&2; exit 1 ;;
esac
hashes=$(awk '{print $2}' <<<"$matches" | sort -u)
count=$(printf '%s' "$hashes" | grep -c . || true)
if [ "$count" = 0 ]; then
  echo "error: no valid \"Developer ID Application\" identity of team $TEAM_ID in the keychain (see docs/notes/signing.md)" >&2
  exit 1
elif [ "$count" != 1 ]; then
  echo "error: $count \"Developer ID Application\" identities of team $TEAM_ID; set SIGN_IDENTITY to the full name of one of them" >&2
  exit 1
fi
printf '%s\n' "$hashes"
