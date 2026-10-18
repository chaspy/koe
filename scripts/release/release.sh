#!/usr/bin/env bash
# Builds and (with --publish) publishes Koe X.Y.Z. Maintainer only.
#
#   scripts/release/release.sh 0.9.0                  # dry run: everything but pushing
#   scripts/release/release.sh 0.9.0 --publish        # push and create the GitHub Release
#   scripts/release/release.sh 0.9.0 --no-notarize    # Developer ID signed, not notarized
#   scripts/release/release.sh 0.9.0 --ref <rev>      # dry run from another revision
#   scripts/release/release.sh 0.9.1 --mac-only       # macOS only: no Windows zip; the
#       Windows notes stay in changelog.d/ for the next release (### Windows says
#       "No changes."), so the Windows app keeps its version
#
# Works in a fresh worktree of origin/main (or --ref) under $KOE_RELEASE_DIR
# (default ~/Library/Caches/koe-release/X.Y.Z), so the checkout you run it
# from is never changed:
#   1. preconditions: clean, up-to-date main; gh login; Developer ID identity
#      of team $TEAM_ID; notarytool profile "koe"; the scrub denylist
#   2. all tests (macOS, Windows, eval, scripts)
#   3. the dev commit "release: X.Y.Z": Info.plist version, and the changelog.d/
#      fragments folded into "## X.Y.Z — <date>" of CHANGELOG.md (scripts/changelog.py)
#   4. scrub of what the public repository gains (scrub.sh)
#   5. Koe-X.Y.Z.dmg (Developer ID, hardened runtime, notarized, stapled) and
#      Koe-X.Y.Z-windows-x64.zip
#   6. the public commit "Koe X.Y.Z": the same tree as the dev commit, its
#      parent the current public main (one commit per release)
#   7. --publish: push dev main, public main and the tags vX.Y.Z, create the
#      Release on chaspy/koe with the CHANGELOG section and both files
#   8. download the published dmg (dry run: the local one) and check it with
#      spctl and codesign
# Heavy steps run under nice -n 15 with 4 jobs. See docs/notes/release.md.
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
VERSION="" PUBLISH=0 NO_NOTARIZE=0 MAC_ONLY=0 REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --no-notarize) NO_NOTARIZE=1 ;;
    --mac-only) MAC_ONLY=1 ;;
    --ref) REF="${2:?--ref needs a revision}"; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$VERSION" ] || usage; VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be X.Y.Z: $VERSION" >&2; exit 2; }
if [ "$PUBLISH" = 1 ] && [ -n "$REF" ]; then
  echo "error: --publish always builds origin/main; drop --ref" >&2
  exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
TAG="v$VERSION"
TEAM_ID="${TEAM_ID:-9RQ8WG6688}"
PUBLIC_REPO="${PUBLIC_REPO:-chaspy/koe}"
PUBLIC_URL="https://github.com/$PUBLIC_REPO.git"
NOTARY_PROFILE="${NOTARY_PROFILE:-koe}"
DENYLIST="${KOE_RELEASE_DENYLIST:-$HOME/.config/koe/release-denylist.txt}"
WHISPER_SERVER="${WHISPER_SERVER:-$HOME/.local/src/whisper.cpp/build-static/bin/whisper-server}"
DIR="${KOE_RELEASE_DIR:-$HOME/Library/Caches/koe-release}/$VERSION"
SRC="$DIR/src"
OUT="$DIR/out"
PUBLIC_REF="refs/koe-release/public-main"
NICE=(nice -n 15)
export GOFLAGS="${GOFLAGS:--p=4}"
export PYTHONDONTWRITEBYTECODE=1

step() { printf '\n== %s ==\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
git_root() { git -C "$ROOT" "$@"; }
mode=$([ "$PUBLISH" = 1 ] && echo publish || echo "dry run")
[ "$MAC_ONLY" = 1 ] && mode+=", macOS only"

step "1. preconditions ($mode, Koe $VERSION)"
missing=()
git_root fetch -q origin main
# not "+main:$PUBLIC_REF": with fetch.prune set, git may prune that ref again
git_root fetch -q --no-prune "$PUBLIC_URL" main
git_root update-ref "$PUBLIC_REF" "$(git_root rev-parse --verify "FETCH_HEAD^{commit}")"
REF="${REF:-origin/main}"
BASE=$(git_root rev-parse --verify "$REF^{commit}") || die "unknown revision $REF"
if [ "$PUBLISH" = 1 ]; then
  [ "$(git_root rev-parse --verify -q main || true)" = "$BASE" ] || missing+=("local main is not origin/main (pull or push first)")
  [ -z "$(git_root status --porcelain)" ] || missing+=("the checkout at $ROOT has uncommitted changes")
fi
gh auth status >/dev/null 2>&1 || missing+=("gh is not logged in (gh auth login)")
current=$(git_root show "$BASE:macos/Info.plist" | plutil -extract CFBundleShortVersionString raw -o - -)
python3 - "$VERSION" "$current" <<'EOF' || missing+=("version $VERSION is not newer than $current")
import sys
a, b = (tuple(map(int, v.split("."))) for v in sys.argv[1:])
sys.exit(0 if a > b else 1)
EOF
git ls-remote --exit-code --tags "$PUBLIC_URL" "refs/tags/$TAG" >/dev/null 2>&1 && missing+=("$TAG already exists on $PUBLIC_REPO")
git_root ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && missing+=("$TAG already exists on origin")
TEAM_ID="$TEAM_ID" bash "$ROOT/macos/scripts/developer-id.sh" >/dev/null || missing+=("Developer ID Application identity of team $TEAM_ID")
if [ "$NO_NOTARIZE" = 1 ]; then
  echo "warning: --no-notarize: the dmg will be Developer ID signed but NOT notarized (the release notes say so)" >&2
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  missing+=("notarytool keychain profile \"$NOTARY_PROFILE\": register it with
    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple account> --team-id $TEAM_ID
  or pass --no-notarize to sign with the Developer ID only (not notarized; noted in the release notes)")
fi
[ -f "$DENYLIST" ] || missing+=("scrub denylist $DENYLIST")
[ -x "$WHISPER_SERVER" ] || missing+=("static whisper-server at $WHISPER_SERVER (README: build-static)")
for t in go swift python3 zip hdiutil; do command -v "$t" >/dev/null || missing+=("command $t"); done
if [ ${#missing[@]} -gt 0 ]; then
  printf 'missing: %s\n' "${missing[@]}" >&2
  die "preconditions not met; nothing was changed"
fi
echo "building $REF ($(git_root rev-parse --short "$BASE")) as $VERSION; public main is $(git_root rev-parse --short "$PUBLIC_REF")"

step "2. tests"
if [ -e "$SRC" ]; then git_root worktree remove --force "$SRC" 2>/dev/null || rm -rf "$SRC"; fi
git_root worktree prune
mkdir -p "$DIR"
rm -rf "$OUT" && mkdir -p "$OUT"
git_root worktree add -q --detach "$SRC" "$BASE"
(cd "$SRC/macos" && "${NICE[@]}" make test && "${NICE[@]}" swift build -c release -j 4)
(cd "$SRC/windows" && "${NICE[@]}" go test ./core/... && GOOS=windows "${NICE[@]}" go vet ./...)
(cd "$SRC" && "${NICE[@]}" python3 -m unittest discover -s eval -p 'test_*.py')
(cd "$SRC" && "${NICE[@]}" python3 -m unittest discover -s scripts -p 'test_*.py')
(cd "$SRC" && "${NICE[@]}" python3 -m unittest discover -s scripts/release -p 'test_*.py')

step "3. dev commit: release: $VERSION"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$SRC/macos/Info.plist"
# folds changelog.d/*.md (and a leftover "## Unreleased") into "## X.Y.Z — <date>"
# and prints the line each app's update prompt will show
# (--mac-only: --hold Windows keeps the Windows entries in their fragments)
hold=()
[ "$MAC_ONLY" = 1 ] && hold=(--hold Windows)
python3 -I "$SRC/scripts/changelog.py" release "$VERSION" --date "$(date +%F)" --root "$SRC" ${hold[@]+"${hold[@]}"}
git -C "$SRC" add -A
# only the version, the CHANGELOG and the removal of folded fragments (or, with
# --mac-only, fragments cut down to their Windows entries)
allowed=$'M\tCHANGELOG\\.md|M\tmacos/Info\\.plist|D\tchangelog\\.d/[^/]+\\.md'
[ "$MAC_ONLY" = 1 ] && allowed+=$'|M\tchangelog\\.d/[^/]+\\.md'
unexpected=$(git -C "$SRC" diff --cached --name-status | grep -vxE "$allowed" || true)
[ -z "$unexpected" ] || die "the release commit would also change: $unexpected"
left=$(git -C "$SRC" ls-files 'changelog.d/*.md')
if [ "$MAC_ONLY" = 1 ]; then
  for f in $left; do
    [ "$(grep '^### ' "$SRC/$f" | sort -u)" = "### Windows" ] || die "$f is left with more than Windows entries"
  done
  echo "Windows entries kept for the next release: $(echo "$left" | grep -c . || true) fragment(s)"
else
  [ -z "$left" ] || die "changelog.d/ still has fragments after folding"
fi
for f in CHANGELOG.md macos/Info.plist; do
  git -C "$SRC" diff --cached --quiet -- "$f" && die "the release commit does not change $f"
done
git -C "$SRC" commit -q -m "release: $VERSION"
RELEASE=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" show --stat --format='%h %s' HEAD

step "4. scrub (public main → release)"
bash "$SRC/scripts/release/scrub.sh" --repo "$SRC" --denylist "$DENYLIST" "$PUBLIC_REF" "$RELEASE" \
  || die "scrub found something to check (see above); nothing was published"

step "5. builds"
(cd "$SRC/macos" && "${NICE[@]}" make dist SWIFT_BUILD_FLAGS="-j 4" TEAM_ID="$TEAM_ID" WHISPER_SERVER="$WHISPER_SERVER")
DMG="$OUT/Koe-$VERSION.dmg"
cp "$SRC/macos/build/Koe-$VERSION.dmg" "$DMG"
NOTARIZED=0
if [ "$NO_NOTARIZE" = 1 ]; then
  echo "notarization skipped (--no-notarize): Developer ID signed only"
  # notarize.sh signs the dmg otherwise
  codesign --force --timestamp --sign "$(TEAM_ID="$TEAM_ID" bash "$SRC/macos/scripts/developer-id.sh")" "$DMG"
else
  (cd "$SRC/macos" && TEAM_ID="$TEAM_ID" NOTARY_PROFILE="$NOTARY_PROFILE" bash scripts/notarize.sh "$DMG")
  NOTARIZED=1
fi
ASSETS=("$DMG")
if [ "$MAC_ONLY" = 1 ]; then
  # no Windows zip: the Windows app only offers a release that has one
  echo "Windows build skipped (--mac-only)"
else
  (cd "$SRC/windows" && CACHE="$DIR/../windows-cache" "${NICE[@]}" ./build.sh)
  ZIP="$OUT/Koe-$VERSION-windows-x64.zip"
  cp "$SRC/windows/dist/Koe-windows-x64.zip" "$ZIP"
  grep -qx "Koe/Koe.exe" <(unzip -Z1 "$ZIP") || die "Koe.exe missing from $ZIP"
  ASSETS+=("$ZIP")
fi
notes_args=()
[ "$NOTARIZED" = 1 ] || notes_args=(--not-notarized)
[ "$MAC_ONLY" = 1 ] && notes_args+=(--mac-only)
python3 -I "$SRC/scripts/release/notes.py" "$VERSION" --file "$SRC/CHANGELOG.md" \
  --install "$SRC/scripts/release/install-notes.md" ${notes_args[@]+"${notes_args[@]}"} > "$OUT/notes.md"
(cd "$OUT" && for a in "${ASSETS[@]}"; do basename "$a"; done | xargs shasum -a 256 | tee SHA256SUMS)

step "6. public commit: Koe $VERSION"
TREE=$(git -C "$SRC" rev-parse "$RELEASE^{tree}")
PUBLIC=$(git -C "$SRC" commit-tree "$TREE" -p "$PUBLIC_REF" -m "Koe $VERSION")
[ "$(git -C "$SRC" rev-parse "$PUBLIC^{tree}")" = "$TREE" ] || die "public commit tree differs from the release commit"
git -C "$SRC" diff --quiet "$RELEASE" "$PUBLIC" || die "public commit differs from the release commit"
[ "$(git -C "$SRC" rev-parse "$PUBLIC^")" = "$(git_root rev-parse "$PUBLIC_REF")" ] || die "public commit's parent is not public main"
echo "public $(git -C "$SRC" rev-parse --short "$PUBLIC") (parent $(git_root rev-parse --short "$PUBLIC_REF")), tree $TREE = dev $(git -C "$SRC" rev-parse --short "$RELEASE")"

step "7. publish"
publish_cmds=(
  "git push origin $RELEASE:refs/heads/main"
  "git push $PUBLIC_URL $PUBLIC:refs/heads/main"
  "git push $PUBLIC_URL $PUBLIC:refs/tags/$TAG"
  "git push origin $RELEASE:refs/tags/$TAG"
  "gh release create $TAG --repo $PUBLIC_REPO --verify-tag --title \"Koe $VERSION\" --notes-file $OUT/notes.md ${ASSETS[*]}"
)
if [ "$PUBLISH" = 1 ]; then
  git -C "$SRC" push origin "$RELEASE:refs/heads/main"
  git -C "$SRC" push "$PUBLIC_URL" "$PUBLIC:refs/heads/main"
  git -C "$SRC" push "$PUBLIC_URL" "$PUBLIC:refs/tags/$TAG"
  git -C "$SRC" push origin "$RELEASE:refs/tags/$TAG"
  gh release create "$TAG" --repo "$PUBLIC_REPO" --verify-tag --title "Koe $VERSION" \
    --notes-file "$OUT/notes.md" "${ASSETS[@]}"
else
  echo "dry run; --publish would run:"
  printf '  %s\n' "${publish_cmds[@]}"
fi

step "8. check the dmg"
CHECK="$DMG"
if [ "$PUBLISH" = 1 ]; then
  rm -rf "$DIR/verify" && mkdir -p "$DIR/verify"
  gh release download "$TAG" --repo "$PUBLIC_REPO" -p "Koe-$VERSION.dmg" -D "$DIR/verify"
  CHECK="$DIR/verify/Koe-$VERSION.dmg"
  [ "$(shasum -a 256 < "$CHECK")" = "$(shasum -a 256 < "$DMG")" ] || die "the published dmg differs from the built one"
fi
mnt=$(mktemp -d)
trap 'hdiutil detach -quiet "$mnt" 2>/dev/null || true' EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$CHECK" >/dev/null
codesign --verify --deep --strict --verbose=2 "$mnt/Koe.app"
TEAM_ID="$TEAM_ID" bash "$SRC/macos/scripts/check-signature.sh" --developer-id "$mnt/Koe.app"
if [ "$NOTARIZED" = 1 ]; then
  spctl -a -vvv -t install "$CHECK"
  spctl -a -vvv -t exec "$mnt/Koe.app"
else
  # expected to be rejected without notarization; shown, not fatal
  echo "not notarized (--no-notarize); Gatekeeper is expected to reject:"
  spctl -a -vvv -t install "$CHECK" || true
  spctl -a -vvv -t exec "$mnt/Koe.app" || true
fi
hdiutil detach -quiet "$mnt"

step "done ($mode$([ "$NOTARIZED" = 1 ] || echo ', NOT notarized'))"
echo "dev commit:    $RELEASE"
echo "public commit: $PUBLIC"
echo "files:         $OUT"
[ "$PUBLISH" = 1 ] && echo "release:       https://github.com/$PUBLIC_REPO/releases/tag/$TAG"
echo "worktree:      $SRC (remove with: git worktree remove --force $SRC)"
