#!/usr/bin/env bash
# Unlocks the Koe signing keychain for codesign (password from the login
# keychain). Prints the keychain path if the identity is usable, nothing
# otherwise. Used by macos/Makefile.
NAME="${SIGN_IDENTITY:-Koe Code Signing}"
KC="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/koe-signing.keychain-db}"
[ -f "$KC" ] || exit 0
PW=$(security find-generic-password -s koe-signing-keychain -a "$USER" -w 2>/dev/null) || exit 0
security unlock-keychain -p "$PW" "$KC" 2>/dev/null || exit 0
security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$NAME\"" && echo "$KC" || true
