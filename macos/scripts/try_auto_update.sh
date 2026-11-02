#!/usr/bin/env bash
# 自動更新の入れ替えを、本物の Koe・設定に触れずに試す（手元の確認用。make test には入れない）。
#   scripts/try_auto_update.sh <公開版の Koe-X.Y.Z.dmg>
# 127.0.0.1 の HTTP から dmg を落とし、アプリと同じ UpdateInstall で取り出す → 署名を確かめる → 入れ替える。
#   busy:        署名は通るが、直前に録音が始まった → 入れ替えない
#   replace:     署名が通る → 一時フォルダの target を置き換え、relaunch（記録だけ）を呼ぶ
#   verify-fail: Koe の Developer ID でない（ad-hoc 署名・別の bundle id）→ 入れない
set -euo pipefail
GOOD=${1:?usage: try_auto_update.sh Koe-X.Y.Z.dmg}
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/koe-tryupdate.XXXXXX")
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$W"; }
trap cleanup EXIT

swiftc -O -o "$W/tryupdate" "$HERE/Sources/Koe/UpdateInstall.swift" "$HERE/Sources/Koe/UpdateVerify.swift" \
  "$HERE/Sources/Koe/AutoUpdate.swift" "$HERE/scripts/tryupdate/main.swift"

mkdir -p "$W/www"
cp "$GOOD" "$W/www/good.dmg"
# 署名が通らない版: 別の bundle id、ad-hoc 署名
mkdir -p "$W/bad/Koe.app/Contents/MacOS"
cp /bin/echo "$W/bad/Koe.app/Contents/MacOS/Koe"
cat >"$W/bad/Koe.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.chaspy.koe.tryupdate</string>
<key>CFBundleExecutable</key><string>Koe</string><key>CFBundleShortVersionString</key><string>9.9.9</string>
</dict></plist>
PLIST
codesign -s - --force "$W/bad/Koe.app" 2>/dev/null
hdiutil create -quiet -volname bad -srcfolder "$W/bad" -format UDZO "$W/www/bad.dmg"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/www" >/dev/null 2>&1 &
PIDS+=($!)
sleep 1
BASE="http://127.0.0.1:$PORT"

# 入れ替えられる側（今の Koe の代わり）
new_target() { rm -rf "$W/target"; mkdir -p "$W/target/Koe.app/Contents"; echo old >"$W/target/Koe.app/Contents/old-marker"; }
fail=0
ok() { echo "ok: $*"; }
ng() { echo "NG: $*"; fail=1; }

echo "== busy"
new_target
"$W/tryupdate" "$BASE/good.dmg" "$W/target/Koe.app" busy "$W/relaunch" | tee "$W/out"
if grep -q "deferred work_removed=true" "$W/out" && [ -f "$W/target/Koe.app/Contents/old-marker" ] && [ ! -e "$W/relaunch" ]; then
  ok "busy: not replaced, staged copy removed, no relaunch"
else
  ng busy
fi

echo "== verify-fail"
new_target
"$W/tryupdate" "$BASE/bad.dmg" "$W/target/Koe.app" verify-fail "$W/relaunch" | tee "$W/out"
if grep -q "reason=verify" "$W/out" && [ -f "$W/target/Koe.app/Contents/old-marker" ] && [ ! -e "$W/relaunch" ]; then
  ok "verify-fail: not replaced, no relaunch"
else
  ng verify-fail
fi

echo "== replace"
new_target
"$W/tryupdate" "$BASE/good.dmg" "$W/target/Koe.app" replace "$W/relaunch" | tee "$W/out"
for _ in $(seq 1 60); do [ -e "$W/relaunch" ] && break; sleep 0.5; done
v=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$W/target/Koe.app/Contents/Info.plist" 2>/dev/null || true)
if [ ! -e "$W/target/Koe.app/Contents/old-marker" ] && [ -n "$v" ] && [ "$(cat "$W/relaunch" 2>/dev/null)" = "$W/target/Koe.app" ] \
   && codesign --verify --strict --deep "$W/target/Koe.app" 2>/dev/null; then
  ok "replace: target is v$v (signature valid), relaunch called with the target"
else
  ng "replace (version=$v)"
fi
exit $fail
