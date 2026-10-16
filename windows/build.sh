#!/usr/bin/env bash
# Builds windows/dist/Koe-windows-x64.zip on macOS / Linux (cross-compile).
#   ./build.sh            # test, build, package
# Needs: go, curl (or gh), unzip, zip. ffmpeg only if assets/*.wav are missing.
set -euo pipefail
cd "$(dirname "$0")"

WHISPER_TAG="${WHISPER_TAG:-v1.9.2}"
WHISPER_ASSET="whisper-bin-x64.zip"
CACHE=".cache"
STAGE="dist/Koe"
ZIP="dist/Koe-windows-x64.zip"
# same version as the mac app (CFBundleShortVersionString); used by the in-app updater
VERSION="${VERSION:-$(awk '/<key>CFBundleShortVersionString<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit}' ../macos/Info.plist)}"
[ -n "$VERSION" ] || { echo "CFBundleShortVersionString not found in ../macos/Info.plist" >&2; exit 1; }
REV="${REV:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"

echo "== test (pure logic) =="
go vet ./...
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go vet ./...
go test ./core

echo "== sounds =="
mkdir -p assets
for n in start stop fail; do
  if [ ! -f "assets/$n.wav" ]; then
    # the start sound leaks into the mic; keep it quiet (mac plays it at volume 0.35)
    vol=1.0; [ "$n" = start ] && vol=0.35
    ffmpeg -loglevel error -y -i "../macos/Resources/$n.aiff" -af "volume=$vol" -ar 44100 -ac 1 -c:a pcm_s16le "assets/$n.wav"
  fi
done

echo "== whisper.cpp $WHISPER_TAG =="
mkdir -p "$CACHE"
CZIP="$CACHE/whisper-bin-x64-$WHISPER_TAG.zip"
if [ ! -s "$CZIP" ]; then
  url="https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_TAG/$WHISPER_ASSET"
  curl -fL --retry 3 -o "$CZIP.tmp" "$url" \
    || gh release download "$WHISPER_TAG" -R ggml-org/whisper.cpp -p "$WHISPER_ASSET" -O "$CZIP.tmp" --clobber
  mv "$CZIP.tmp" "$CZIP"
fi
WDIR="$CACHE/whisper-$WHISPER_TAG"
if [ ! -f "$WDIR/whisper-server.exe" ]; then
  mkdir -p "$WDIR"
  # only the server and its DLLs (the zip also has many example tools)
  unzip -q -o -j "$CZIP" '*/whisper-server.exe' '*.dll' -d "$WDIR"
  [ -f "$WDIR/whisper-server.exe" ] || { echo "whisper-server.exe not in $CZIP" >&2; exit 1; }
fi

echo "== whisper.cpp $WHISPER_TAG Vulkan (GPU) =="
# built by .github/workflows/whisper-vulkan.yml; taken from its latest
# successful run on main. Without it Koe still works (CPU only).
VDIR="$CACHE/vulkan-$WHISPER_TAG"
if [ ! -f "$VDIR/whisper-server-vulkan.exe" ] && [ "${SKIP_VULKAN:-}" != 1 ]; then
  VULKAN_REPO="${VULKAN_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
  run=$(gh run list -R "$VULKAN_REPO" -w whisper-vulkan.yml -b main -s success -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  if [ -n "$run" ]; then
    gh run download "$run" -R "$VULKAN_REPO" -n "whisper-server-vulkan-$WHISPER_TAG" -D "$VDIR" || true
  fi
fi
if [ -f "$VDIR/whisper-server-vulkan.exe" ]; then
  cat "$VDIR/vulkan-build.txt" 2>/dev/null || true
else
  echo "warning: no whisper-server-vulkan.exe (run the whisper-vulkan workflow, or SKIP_VULKAN=1); building without GPU support" >&2
fi

echo "== build Koe.exe ($VERSION, $REV) =="
mkdir -p "$STAGE"
find "$STAGE" -mindepth 1 -delete
mkdir -p "$STAGE/packs" "$STAGE/assets"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath \
  -ldflags "-H windowsgui -s -w -X main.version=$VERSION -X main.rev=$REV" -o "$STAGE/Koe.exe" .
cp "$WDIR"/whisper-server.exe "$WDIR"/*.dll "$STAGE/"
[ -f "$VDIR/whisper-server-vulkan.exe" ] && cp "$VDIR/whisper-server-vulkan.exe" "$STAGE/"
cp ../packs/*.txt "$STAGE/packs/"
cp assets/*.wav "$STAGE/assets/"
cp README-windows.md "$STAGE/"
cp ../CONTRIBUTING.md "$STAGE/"

echo "== zip =="
rm -f "$ZIP"
(cd dist && zip -qr "$(basename "$ZIP")" Koe)
ls -la "$ZIP"
