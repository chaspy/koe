#!/usr/bin/env bash
# Pre-publication check of what a release adds to the public repository; see
# scrub.py for what it looks for. Prints only path:line and a category, never
# the matched text. Exit 0 clean, 1 hits, 2 setup error.
#   bash scripts/release/scrub.sh public/main HEAD
#   bash scripts/release/scrub.sh --denylist <file> <base> <target>
set -euo pipefail
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/scrub.py" "$@"
