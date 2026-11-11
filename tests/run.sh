#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$DIR/.." && pwd)"
NVIM_APPNAME=orch-test
export NVIM_APPNAME

for t in "$DIR"/*_test.lua; do
  [ -f "$t" ] || continue
  echo "--- $(basename "$t")"
  nvim --headless -u "$DIR/minimal_init.lua" -l "$t"
done

echo "=== ALL TESTS PASSED ==="
