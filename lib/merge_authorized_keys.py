# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Merge wanted public keys into authorized_keys.

modify_ helper: existing content on stdin, merged content on stdout.
Usage: merge_authorized_keys.py PUB_LIST
"""
import sys
from pathlib import Path

KEY_TYPES = ("ssh-", "ecdsa-", "sk-")


def key_id(line):
    """(type, body) of an authorized_keys line, ignoring options and comment."""
    fields = line.split()
    for i, f in enumerate(fields[:-1]):
        if f.startswith(KEY_TYPES):
            return (f, fields[i + 1])
    return None


def merge(existing, wanted):
    """Keep every existing line; append wanted keys not already present."""
    lines = existing.rstrip("\n").split("\n") if existing.strip("\n") else []
    have = {k for k in map(key_id, lines) if k}
    for w in wanted:
        k = key_id(w)
        if k is None or k in have:
            continue
        have.add(k)
        lines.append(w.strip())
    return "\n".join(lines) + "\n" if lines else ""


def read_list(path):
    out = []
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def main(argv):
    if len(argv) != 2:
        print("usage: merge_authorized_keys.py PUB_LIST", file=sys.stderr)
        return 2
    sys.stdout.write(merge(sys.stdin.read(), read_list(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
