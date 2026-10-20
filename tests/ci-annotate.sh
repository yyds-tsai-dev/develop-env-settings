#!/usr/bin/env bash
# Emit GitHub ::error annotations for the `not ok` blocks of a TAP file.
# Usage: tests/ci-annotate.sh <tap-file> <title>
# Check-run annotations are public even when job logs are not.
set -u
[ "$#" -eq 2 ] || { echo "usage: $0 <tap-file> <title>" >&2; exit 2; }
[ -r "$1" ] || { echo "ci-annotate: cannot read $1" >&2; exit 0; }

awk -v title="$2" '
function esc(s) {
  gsub(/%/, "%25", s); gsub(/\r/, "%0D", s); gsub(/:/, "%3A", s); gsub(/,/, "%2C", s)
  return s
}
function msg(s) { gsub(/%/, "%25", s); gsub(/\r/, "%0D", s); return s }
function flush() {
  if (cur != "") { printf "::error title=%s::%s\n", esc(title), cur; cur = "" }
  open = 0
}
/^not ok/ {
  flush()
  if (count >= 10) next
  count++; open = 1; n = 0
  line = $0; sub(/\r$/, "", line)
  cur = msg(line)
  next
}
open && /^[ \t]*#/ {
  if (n < 15) { line = $0; sub(/\r$/, "", line); cur = cur "%0A" msg(line); n++ }
  next
}
{ flush() }
END { flush() }
' "$1"
exit 0
