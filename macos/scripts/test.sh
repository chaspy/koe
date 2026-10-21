#!/usr/bin/env bash
# Builds and runs every Tests/<name>/main.swift (the Command Line Tools have no
# XCTest, so each test is compiled with swiftc). A test lists the files it
# needs, relative to Sources/Koe, on a line of its main.swift:
#   // test-sources: People.swift AliasReplace.swift
# Objective-C files (e.g. ../KoeObjC/KoeObjC.m) are compiled with clang, C++20 files
# (../KoeAudioCore/koe_audio.cpp) with clang++, and
# the include directory next to them is passed to swiftc.
#   bash scripts/test.sh          # all tests (make test)
#   bash scripts/test.sh people   # one test (make test T=people)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
all=""
for d in Tests/*/; do all="$all$(basename "$d") "; done
if [ -n "${1:-}" ]; then
  [ -f "Tests/$1/main.swift" ] || { echo "no test Tests/$1/ (one of: ${all% })" >&2; exit 1; }
  names="$1"
else
  names="$all"
fi
n=0
for t in $names; do
  main="Tests/$t/main.swift"
  [ -f "$main" ] || { echo "Tests/$t/ has no main.swift" >&2; exit 1; }
  src=$(sed -n 's|^// test-sources:||p' "$main" | head -1)
  [ -n "$src" ] || { echo "$main: add a line '// test-sources: <files in Sources/Koe>'" >&2; exit 1; }
  inputs=() flags=()
  for f in $src; do
    p="Sources/Koe/$f"
    [ -f "$p" ] || { echo "$main: test-sources names $p, which does not exist" >&2; exit 1; }
    case "$f" in
      *.m)
        inc="$(dirname "$p")/include"
        obj="build/$t-$(basename "$f" .m).o"
        clang -fobjc-arc -I "$inc" -c "$p" -o "$obj"
        inputs+=("$obj") flags+=(-I "$inc") ;;
      *.cpp)
        inc="$(dirname "$p")/include"
        obj="build/$t-$(basename "$f" .cpp).o"
        clang++ -std=c++20 -O1 -I "$inc" -c "$p" -o "$obj"
        inputs+=("$obj") flags+=(-I "$inc" -Xlinker -lc++) ;;
      *) inputs+=("$p") ;;
    esac
  done
  echo "swiftc $t:$src"
  swiftc -O ${flags[@]+"${flags[@]}"} -o "build/$t-test" "${inputs[@]}" "$main"
  "./build/$t-test"
  n=$((n + 1))
done
echo "make test: $n test(s) passed"
