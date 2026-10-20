#!/usr/bin/env bash
# Turn a CI Bootstrap's output into ::error annotations through tests/ci-annotate.sh:
# one block per Doctor FAIL line (doctor.out) plus the tail of bootstrap.out.
# Usage: tests/ci-annotate-bootstrap.sh <title>   (run from the repo root)
set -u
[ "$#" -eq 1 ] || { echo "usage: $0 <title>" >&2; exit 2; }
tap="$(mktemp)"
{
  [ -r doctor.out ] && sed -n 's/\r$//; s/^FAIL /not ok doctor FAIL /p' doctor.out
  if [ -r bootstrap.out ]; then
    echo "not ok bootstrap output (last 15 lines)"
    tail -n 15 bootstrap.out | sed 's/\r$//; s/^/# /'
  fi
} > "$tap"
"$(dirname "$0")/ci-annotate.sh" "$tap" "$1"
rm -f "$tap"
exit 0
