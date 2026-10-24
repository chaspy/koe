# Shared audio quality and cgo builds

The C API in `macos/Sources/KoeAudioCore` is the single audio-quality implementation.
The imported files retain their koe-audio-core origin, commit 00fe10f. Go compiles
that same source via `windows/core/audio_quality_bridge.cpp`; it does not carry a
second copy. Keeping the source in place avoids a SwiftPM target move and preserves
upstream provenance. Upstream implementation changes must be made in koe-audio-core.

## Native tests and Windows cross-builds on macOS

Install Xcode Command Line Tools (native clang/clang++) and `brew install mingw-w64`.
Go alone is no longer sufficient: cgo needs both a C and a C++20 compiler.
Run from the repository root:

```sh
cd windows
CGO_ENABLED=1 nice -n 15 go test ./core/...
GOOS=windows GOARCH=amd64 CGO_ENABLED=1 \
  CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ \
  nice -n 15 go build -p 4 -o /tmp/Koe-audio-test.exe .
GOOS=windows GOARCH=amd64 CGO_ENABLED=1 \
  CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ \
  nice -n 15 go vet -p 4 ./...
```

Keep the native host compilers for the first command. Set both `CC` and `CXX` for
cross-builds; `CC` alone does not select the C++ compiler. Cross-vet also requires
cgo and the target compilers. There is no pure-Go fallback for `CGO_ENABLED=0`.
On Windows use a C++20-capable MinGW gcc/g++ toolchain and `CGO_ENABLED=1`.

`windows/build.sh` performs native tests and Windows cross-vet, builds with cgo,
and packages the app. `WINDOWS_CC` / `WINDOWS_CXX` can override its cross-compilers.
The release script uses those same overrides for its preflight vet. Windows links
the C++ runtime statically, so the bridge does not add MinGW runtime DLLs to the
package. Building a package is not a release or authorization to distribute it.

## Behavior and fixtures

Pass the full 16 kHz mono recording, including background windows, to the C API.
Windows previously measured RMS over the silence-trimmed recording. It now uses
macOS's 30 ms windows, lower-decile background, speech floor, rounded metrics and
0.3-second minimum voiced duration for the optional quiet-voice notice. This can
change Windows level values and notices, especially for short or steady sounds.
The existing speech trimming, mute detection and ASR input selection are unchanged.

Both bindings use `testdata/audio-quality.json`: deterministic synthetic waveforms
with frozen outputs from the pre-unification Swift code. See `testdata/README.md`.
No private recordings are needed. Cross-build and native tests do not validate
Windows microphone capture or UI behavior. As with #172, verify on a real Windows
machine before distributing; this change does not publish a release.
