#!/usr/bin/env bash
# Stop `make install` from putting a second Koe.app next to the one in
# /Applications (usually the public dmg). With two copies, the one that opens
# from Launchpad or at login may be the old one, and the Accessibility list
# shows two "Koe" entries that look the same.
#   check-install-dir.sh <INSTALL_DIR> <$(origin INSTALL_DIR)>
# Only the default INSTALL_DIR (origin "file") is checked: an INSTALL_DIR given
# on the command line or in the environment is the user's choice.
set -euo pipefail
dir="${1%/}"
origin="$2"
system="${KOE_SYSTEM_APPS:-/Applications}"
[ "$origin" = file ] || exit 0
[ -d "$system/Koe.app" ] || exit 0
[ "$dir" = "$system" ] && exit 0
cat >&2 <<EOF
error: $system/Koe.app already exists, and make install would add a second Koe.app in $dir.
  Replace the one in $system:  make install INSTALL_DIR=$system
  Keep both anyway:            make install INSTALL_DIR=$dir
If the installed app was signed with another certificate (for example the public dmg), grant the Accessibility and Microphone permissions again afterwards: see docs/notes/signing.md.
EOF
exit 1
