#!/bin/bash
# Uses the built Koe only in its internal watcher mode. Never launches the app,
# reads user state, or signals an existing Koe/whisper-server process.
set -euo pipefail
cd "$(dirname "$0")/../.."
helper="$(pwd)/.build/release/Koe"
if [[ ! -x "$helper" ]]; then
  echo 'Build first: nice -n 15 swift build -c release -j 4' >&2
  exit 1
fi
KOE_LIFETIME_HELPER="$helper" nice -n 15 make test T=server-lifecycle
