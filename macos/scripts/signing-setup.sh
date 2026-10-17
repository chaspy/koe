#!/usr/bin/env bash
# Creates the "Koe Code Signing" certificate once per Mac, so every build of
# Koe.app has the same designated requirement and macOS keeps the
# Accessibility / Microphone permissions across updates (ad-hoc signatures
# change with every build). See docs/notes/signing.md.
#
# The identity lives in its own keychain (koe-signing.keychain-db) whose
# random password is stored in the login keychain, so builds can unlock it
# and codesign never shows a dialog. Nothing secret is written to the repo.
#   bash macos/scripts/signing-setup.sh              # create (no-op if present)
#   bash macos/scripts/signing-setup.sh --import X.p12   # use an exported identity instead
set -euo pipefail
NAME="${SIGN_IDENTITY:-Koe Code Signing}"
KC="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/koe-signing.keychain-db}"
SVC=koe-signing-keychain

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "already set up: $KC"; security find-certificate -c "$NAME" -Z "$KC" | grep SHA-1; exit 0
fi

KCPW=$(openssl rand -hex 24)
security add-generic-password -U -s "$SVC" -a "$USER" -w "$KCPW" -T /usr/bin/security \
  -l "Koe signing keychain password" "$HOME/Library/Keychains/login.keychain-db"
[ -f "$KC" ] && security delete-keychain "$KC"
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings "$KC" # no auto-lock
security unlock-keychain -p "$KCPW" "$KC"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; chmod 700 "$TMP"
if [ "${1:-}" = --import ]; then
  P12="$2"; read -r -s -p "p12 password: " P12PW; echo
else
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
  P12="$TMP/koe.p12"; P12PW=$(openssl rand -hex 16)
  # OpenSSL 3 defaults are not compatible with macOS security import.
  # OpenSSL 1.1 and Apple's LibreSSL do not support -legacy.
  P12_OPTIONS=(-export)
  case "$(openssl version)" in
    "OpenSSL 3."*) P12_OPTIONS+=(-legacy) ;;
  esac
  openssl pkcs12 "${P12_OPTIONS[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$P12" -passout "pass:$P12PW"
fi
if security import "$P12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign -T /usr/bin/security >/dev/null; then
  :
else
  status=$?
  echo "error: signing identity import failed; removing incomplete signing setup" >&2
  security delete-keychain "$KC" || echo "warning: could not remove $KC" >&2
  security delete-generic-password -s "$SVC" -a "$USER" \
    "$HOME/Library/Keychains/login.keychain-db" || \
    echo "warning: could not remove signing keychain password" >&2
  exit "$status"
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
# keep the keychain in the user's search list (codesign is also given --keychain)
LIST=$(security list-keychains -d user | tr -d '"' | xargs)
case " $LIST " in *" $KC "*) ;; *) security list-keychains -d user -s $LIST "$KC" ;; esac
echo "created: $KC"
security find-certificate -c "$NAME" -Z "$KC" | grep SHA-1
