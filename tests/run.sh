#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in "$DIR"/*_test.lua; do
  [ -f "$t" ] || continue
  echo "--- $(basename "$t")"
  nvim --headless -u NONE -l "$t"
done
echo "=== ALL TESTS PASSED ==="
