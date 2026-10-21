#!/usr/bin/env bash
# Turn a CI Bootstrap's output into ::error annotations through tests/ci-annotate.sh:
# one block per Doctor FAIL line (doctor.out) plus the tail of bootstrap.out.
# Usage: tests/ci-annotate-bootstrap.sh <title>   (run from the repo root)
set -u
[ "$#" -eq 1 ] || { echo "usage: $0 <title>" >&2; exit 2; }
tap="$(mktemp)"
{
  [ -r doctor.out ] && tr -d '\r' < doctor.out | sed -n 's/^FAIL /not ok doctor FAIL /p'
  if [ -r bootstrap.out ]; then
    echo "not ok bootstrap output (last 15 lines)"
    tail -n 15 bootstrap.out | tr -d '\r' | sed 's/^/# /'
    # install-script warnings (e.g. 55-codex.ps1's), which the tail usually misses
    w="$(tr -d '\r' < bootstrap.out | sed 's/\x1b\[[0-9;]*m//g' | grep -iE '^(warning|WARNING):|^WARNING ' | tail -n 40)"
    if [ -n "$w" ]; then
      echo "not ok install script warnings (last 40)"
      printf '%s\n' "$w" | sed 's/^/# /'
    fi
  fi
} > "$tap"
"$(dirname "$0")/ci-annotate.sh" "$tap" "$1"
rm -f "$tap"
exit 0
