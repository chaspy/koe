#!/usr/bin/env bash
# Warn before replacing an installed app with a different signing requirement.
set -euo pipefail
installed="$1"
built="$2"
[ -d "$installed" ] || exit 0

requirement() {
  codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'
}

if old_requirement=$(requirement "$installed") && \
   new_requirement=$(requirement "$built") && \
   [ -n "$old_requirement" ] && [ -n "$new_requirement" ]; then
  if [ "$old_requirement" != "$new_requirement" ]; then
    echo "警告: 署名が変わるため Accessibility / マイクの許可を一度削除して再追加する必要があります。手順: docs/notes/signing.md" >&2
  fi
else
  echo "警告: 署名を確認できませんでした。入れ替え後に Accessibility / マイクの再許可が必要になる場合があります。手順: docs/notes/signing.md" >&2
fi
