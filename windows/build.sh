#!/usr/bin/env bash
# Builds windows/dist/Koe-windows-x64.zip on macOS / Linux (cross-compile).
#   ./build.sh            # test, build, package
# Needs: go, curl (or gh), unzip, zip. ffmpeg only if assets/*.wav are missing.
set -euo pipefail
cd "$(dirname "$0")"

WHISPER_TAG="${WHISPER_TAG:-v1.9.2}"
WHISPER_ASSET="whisper-bin-x64.zip"
# sha256 of $WHISPER_ASSET: the "digest" GitHub shows for the asset in the
# ggml-org/whisper.cpp v1.9.2 release, checked 2026-10-18 against a download.
# Set both when changing WHISPER_TAG.
WHISPER_SHA256="${WHISPER_SHA256:-49dcc16de826f20bd53d44f947a1ae49dfa81f86cad67a64d80820cb192d674a}"
# sha256 of whisper-server-vulkan.exe from the whisper-vulkan workflow (run
# 38825703725, 2026-10-15). After running the workflow again, check the new
# artifact and set this to its hash.
VULKAN_SHA256="${VULKAN_SHA256:-dce8936bc017c5ecb91902f200a1dbbb99069f11731b93f8d9c157b7c167075f}"
# sherpa-onnx for engine "parakeet" (core.SherpaVersion; core.sherpaRecognizerConfig matches its c-api.h)
SHERPA_TAG="${SHERPA_TAG:-v1.13.8}"
SHERPA_NAME="sherpa-onnx-$SHERPA_TAG-win-x64-shared-MT-Release-no-tts"
# sha256 of $SHERPA_NAME.tar.bz2: the "digest" GitHub shows for the asset in the
# k2-fsa/sherpa-onnx v1.13.8 release, checked 2026-10-17 against a download.
# Set both when changing SHERPA_TAG.
SHERPA_SHA256="${SHERPA_SHA256:-4b0a94f7b5c606b1b64a19a831c2127559e4b3d34e195465ebc7be73d9ed4783}"
CACHE="${CACHE:-.cache}"  # downloads; the release script keeps one outside the worktree
STAGE="dist/Koe"
ZIP="dist/Koe-windows-x64.zip"
# same version as the mac app (CFBundleShortVersionString); used by the in-app updater
VERSION="${VERSION:-$(awk '/<key>CFBundleShortVersionString<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit}' ../macos/Info.plist)}"
[ -n "$VERSION" ] || { echo "CFBundleShortVersionString not found in ../macos/Info.plist" >&2; exit 1; }
REV="${REV:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"

# check_sha256 <file> <want> <what to remove on mismatch>: stops the build on a mismatch
check_sha256() {
  local got
  got=$( (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | awk '{print $1}')
  if [ "$got" != "$2" ]; then
    rm -rf "$3"
    echo "sha256 mismatch for $(basename "$1"): got $got, want $2 (removed; not shipped)" >&2
    exit 1
  fi
}

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
# checked on every build, and unpacked again from the checked zip
check_sha256 "$CZIP" "$WHISPER_SHA256" "$CZIP"
WDIR="$CACHE/whisper-$WHISPER_TAG"
rm -rf "$WDIR"
mkdir -p "$WDIR"
# only the server and its DLLs (the zip also has many example tools)
unzip -q -o -j "$CZIP" '*/whisper-server.exe' '*.dll' -d "$WDIR"
[ -f "$WDIR/whisper-server.exe" ] || { echo "whisper-server.exe not in $CZIP" >&2; exit 1; }

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
  check_sha256 "$VDIR/whisper-server-vulkan.exe" "$VULKAN_SHA256" "$VDIR"
  cat "$VDIR/vulkan-build.txt" 2>/dev/null || true
else
  echo "warning: no whisper-server-vulkan.exe (run the whisper-vulkan workflow, or SKIP_VULKAN=1); building without GPU support" >&2
fi

echo "== sherpa-onnx $SHERPA_TAG (engine \"parakeet\") =="
# static CRT (MT) build: no Visual C++ runtime needed. Only the C API DLL and
# onnxruntime are shipped; Koe.exe loads them at run time when engine is parakeet.
SDIR="$CACHE/sherpa-$SHERPA_TAG"
if [ ! -f "$SDIR/sherpa-onnx-c-api.dll" ]; then
  STAR="$CACHE/$SHERPA_NAME.tar.bz2"
  [ -s "$STAR" ] || { curl -fL --retry 3 -o "$STAR.tmp" "https://github.com/k2-fsa/sherpa-onnx/releases/download/$SHERPA_TAG/$SHERPA_NAME.tar.bz2" && mv "$STAR.tmp" "$STAR"; }
  check_sha256 "$STAR" "$SHERPA_SHA256" "$STAR"
  mkdir -p "$SDIR"
  tar -xjf "$STAR" -C "$SDIR" --strip-components=2 \
    "$SHERPA_NAME/lib/sherpa-onnx-c-api.dll" "$SHERPA_NAME/lib/onnxruntime.dll" "$SHERPA_NAME/lib/onnxruntime_providers_shared.dll"
  [ -f "$SDIR/sherpa-onnx-c-api.dll" ] || { echo "sherpa-onnx-c-api.dll not in $STAR" >&2; exit 1; }
fi

echo "== build Koe.exe ($VERSION, $REV) =="
mkdir -p "$STAGE"
find "$STAGE" -mindepth 1 -delete
mkdir -p "$STAGE/packs" "$STAGE/assets"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath \
  -ldflags "-H windowsgui -s -w -X main.version=$VERSION -X main.rev=$REV" -o "$STAGE/Koe.exe" .
cp "$WDIR"/whisper-server.exe "$WDIR"/*.dll "$STAGE/"
[ -f "$VDIR/whisper-server-vulkan.exe" ] && cp "$VDIR/whisper-server-vulkan.exe" "$STAGE/"
cp "$SDIR"/*.dll "$STAGE/"
cp ../packs/*.txt "$STAGE/packs/"
cp assets/*.wav "$STAGE/assets/"
cp README-windows.md "$STAGE/"
cp ../CONTRIBUTING.md "$STAGE/"
cp THIRD_PARTY_NOTICES.md "$STAGE/"

echo "== zip =="
rm -f "$ZIP"
(cd dist && zip -qr "$(basename "$ZIP")" Koe)
ls -la "$ZIP"
