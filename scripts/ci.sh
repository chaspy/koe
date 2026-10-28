#!/usr/bin/env bash
# Local CI: the gate before merging. Paste the last line (and any failing
# stage) into the PR description. GitHub Actions runs only as a manual check
# before a release.
#   scripts/ci.sh                 # compare with origin/main
#   CI_BASE=<rev> scripts/ci.sh   # compare with another base
# Runs every stage even after a failure, then prints one line:
#   ci: pass macos-test=95s macos-release=60s ... (exit 0) / ci: fail ... (exit 1)
# A stage that cannot run here prints "skip: <reason>" and does not fail.
set -uo pipefail

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
BASE=${CI_BASE:-origin/main}
NICE=(nice -n 15)
WINDOWS_CC=${WINDOWS_CC:-x86_64-w64-mingw32-gcc}
WINDOWS_CXX=${WINDOWS_CXX:-x86_64-w64-mingw32-g++}
summary=()
failed=0

# stage <name> <command...>: runs the command from $ROOT and records its time.
# Exit 77 from the command means skipped.
stage() {
  local name=$1; shift
  printf '\n== %s ==\n' "$name"
  local start=$SECONDS rc=0
  (cd "$ROOT" && "$@") || rc=$?
  local secs=$((SECONDS - start)) mark=""
  if [ "$rc" = 77 ]; then
    mark="(skip)"
  elif [ "$rc" != 0 ]; then
    mark="(FAIL)"; failed=1
  fi
  summary+=("$name=${secs}s$mark")
}

macos_test() { cd macos && "${NICE[@]}" make test; }
macos_release() { cd macos && "${NICE[@]}" swift build -c release -j 4; }

windows_native() {
  cd windows && CGO_ENABLED=1 "${NICE[@]}" go vet ./... && CGO_ENABLED=1 "${NICE[@]}" go test ./...
}

windows_cross() {
  if ! command -v "$WINDOWS_CC" >/dev/null || ! command -v "$WINDOWS_CXX" >/dev/null; then
    echo "skip: $WINDOWS_CC / $WINDOWS_CXX not found (brew install mingw-w64; windows/README-windows.md)"
    return 77
  fi
  cd windows && export GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC="$WINDOWS_CC" CXX="$WINDOWS_CXX" &&
    "${NICE[@]}" go vet ./... && "${NICE[@]}" go build -o /dev/null .
}

# Tests that need numpy and the like skip themselves when it is missing
# (unittest prints "skipped=N" with the reasons under -v).
python_tests() {
  local d
  for d in scripts scripts/release eval; do
    echo "-- $d"
    "${NICE[@]}" python3 -m unittest discover -s "$d" -p 'test_*.py' || return 1
  done
}

changelog() { python3 scripts/changelog.py check; }
kagami_check() { kagami check --format agent-brief | tee /dev/stderr | grep -q '^kagami/agent-brief@1 gate=pass '; }
pr_risk() { python3 scripts/pr_risk.py --base "$BASE" --head HEAD; }

stage macos-test macos_test
stage macos-release macos_release
stage windows windows_native
stage windows-cross windows_cross
stage python python_tests
stage changelog changelog
stage kagami kagami_check
stage pr-risk pr_risk

result=pass
[ "$failed" = 0 ] || result=fail
printf '\nci: %s %s (%s)\n' "$result" "${summary[*]}" "$(git -C "$ROOT" rev-parse --short HEAD)"
[ "$failed" = 0 ]
