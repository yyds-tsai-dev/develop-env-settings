# /// script
# requires-python = ">=3.9"
# dependencies = ["tomlkit"]
# ///
"""Merge the managed Codex fragment into ~/.codex/config.toml.

modify_ helper: existing content on stdin, merged content on stdout.
Usage: merge_codex_config.py MANAGED_TOML

Every key in the fragment replaces the existing one (tables merge key by key,
arrays and arrays of tables are replaced whole). `mcp_servers` is replaced
wholesale, so servers absent from the fragment are removed. Everything the
fragment does not mention (`[projects.*]`, `hooks.state`, ...) is kept, with
its comments. Consecutive blank lines are collapsed to one, so the first merge
is already a fixpoint. Before printing, the result is parsed back and checked:
every input key the fragment does not replace must keep its value at the same
path, and every managed key must hold the fragment's value; otherwise it
raises (exit 1), and the modify_ script keeps the current file.
"""
import re
import sys
from pathlib import Path

import tomlkit
from tomlkit.items import AoT, InlineTable, Table
from tomlkit.container import Container

WHOLESALE = ("mcp_servers",)


def _is_table(v):
    return isinstance(v, (Table, InlineTable, Container)) and not isinstance(v, AoT)


def _overlay(dst, src):
    for k, v in src.items():
        if _is_table(v) and k in dst and _is_table(dst[k]):
            _overlay(dst[k], v)
        else:
            dst[k] = v


def _header_table(doc, k):
    """True when top-level `k` is a [table] (or super table), not a dotted key
    or an inline table."""
    for key, item in doc.body:
        if key is not None and key.key == k:
            return isinstance(item, Table) and not key.is_dotted()
    return False


def _check_timeouts(managed):
    for name, srv in (managed.get("mcp_servers") or {}).items():
        if "tool_timeout_sec" not in srv:
            raise ValueError(f"mcp_servers.{name}: tool_timeout_sec is required")


def merge(existing, managed):
    m = tomlkit.parse(managed)
    _check_timeouts(m)
    doc = tomlkit.parse(existing if existing.strip() else "")
    for k in WHOLESALE:
        if k in doc and (k not in m or not _header_table(doc, k)):
            # a dotted `mcp_servers.x.y = ...` or inline value: replacing it in
            # place would put the new tables mid-document; re-add at the end
            del doc[k]
    for k, v in m.items():
        if k in WHOLESALE:
            doc[k] = v
        elif _is_table(v) and k in doc and _is_table(doc[k]):
            _overlay(doc[k], v)
        else:
            doc[k] = v
    out = re.sub(r"\n{3,}", "\n\n", tomlkit.dumps(doc))
    check(existing, managed, out)
    return out


_MISSING = object()


def _leaves(d, prefix=()):
    for k, v in d.items():
        p = prefix + (k,)
        if isinstance(v, dict) and v:
            yield from _leaves(v, p)
        else:
            yield p, v


def _get(d, path):
    for k in path:
        if not isinstance(d, dict) or k not in d:
            return _MISSING
        d = d[k]
    return d


def check(existing, managed, out):
    """Raise ValueError unless `out` keeps every unmanaged input value in place
    and holds every managed value."""
    old = tomlkit.parse(existing if existing.strip() else "").unwrap()
    m = tomlkit.parse(managed).unwrap()
    new = tomlkit.parse(out).unwrap()
    replaced = [(k,) for k in WHOLESALE if k in m] + [p for p, _ in _leaves(m)]
    bad = []
    for p, v in _leaves(old):
        if any(p[:len(r)] == r or r[:len(p)] == p for r in replaced):
            continue
        got = _get(new, p)
        if (got != v) if not (isinstance(v, dict) and not v) else not isinstance(got, dict):
            bad.append(".".join(p))
    for k in WHOLESALE:
        if k in m and new.get(k) != m[k]:
            bad.append(k)
    for p, v in _leaves(m):
        if p[0] not in WHOLESALE and _get(new, p) != v:
            bad.append(".".join(p))
    if bad:
        raise ValueError("merged config lost or changed: " + ", ".join(bad))


def main(argv):
    if len(argv) != 2:
        print("usage: merge_codex_config.py MANAGED_TOML", file=sys.stderr)
        return 2
    sys.stdout.write(merge(sys.stdin.read(), Path(argv[1]).read_text()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
