# /// script
# requires-python = ">=3.9"
# dependencies = ["tomlkit"]
# ///
"""Merge the managed Codex fragment into ~/.codex/config.toml.

modify_ helper: existing content on stdin, merged content on stdout.
Usage: merge_codex_config.py MANAGED_TOML
       merge_codex_config.py [--desktop] [--keep-on-error]
           (MANAGED_TOML | --fragment-b64 B64) [--current-file PATH]
--fragment-b64: the fragment as base64 (Windows modify-template, no temp file).
--current-file: read the current config from PATH (missing: empty) instead of
  stdin. Input and output are UTF-8 bytes on every OS.
--desktop: a plain Desktop has only some MCP runtimes: a server whose `command`
  is not on PATH is dropped with one warning (a `url` server is always kept),
  and so is a hook whose command's first word is not on PATH (the
  codebase-memory-mcp hooks before it is installed; a later merge restores
  them). On Windows a command that does not resolve to an .exe (npx.cmd from a
  Node install) becomes `cmd /c <command> ...`, which Codex can start.
Input may start with a UTF-8 BOM (Windows editors); the output has none.
--keep-on-error: when the merge or its check fails, warn and print the current
  config unchanged (exit 0), for callers that cannot fall back themselves.

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
import base64
import os
import re
import shutil
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


def desktop_servers(managed, which=None, windows=None):
    """The fragment with only the MCP servers this machine can start (see
    --desktop). Prints one warning per dropped server."""
    which = which or shutil.which
    windows = (os.name == "nt") if windows is None else windows
    doc = tomlkit.parse(managed)
    servers = doc.get("mcp_servers")
    if not servers:
        return managed
    for name in list(servers.keys()):
        srv = servers[name]
        if "url" in srv or "command" not in srv:
            continue
        cmd = str(srv["command"])
        found = which(cmd)
        if not found:
            print(f"warning: {cmd} not found on this desktop; skipping Codex MCP server {name}", file=sys.stderr)
            del servers[name]
        elif windows and not found.lower().endswith(".exe"):
            srv["args"] = ["/c", cmd] + [str(a) for a in srv.get("args", [])]
            srv["command"] = "cmd"
    hooks = doc.get("hooks")
    if hooks:
        for event in list(hooks.keys()):
            groups = hooks[event]
            if not isinstance(groups, list):
                continue
            for g in list(groups):
                inner = g.get("hooks") if hasattr(g, "get") else None
                if not isinstance(inner, list):
                    continue
                for h in list(inner):
                    first = str(h.get("command", "")).split()[:1]
                    if first and not which(first[0]):
                        print(f"warning: {first[0]} not found on this desktop; skipping Codex hook {event}: {h['command']}", file=sys.stderr)
                        inner.remove(h)
                if not inner:
                    groups.remove(g)
            if not groups:
                del hooks[event]
        if not hooks:
            del doc["hooks"]
    return tomlkit.dumps(doc)


def main(argv):
    if len(argv) == 2 and not argv[1].startswith("--"):
        sys.stdout.write(merge(sys.stdin.read(), Path(argv[1]).read_text()))
        return 0
    desktop = keep = False
    frag = b64 = cur_file = None
    args = argv[1:]
    try:
        while args:
            a = args.pop(0)
            if a == "--desktop":
                desktop = True
            elif a == "--keep-on-error":
                keep = True
            elif a == "--fragment-b64":
                b64 = args.pop(0)
            elif a == "--current-file":
                cur_file = args.pop(0)
            elif not a.startswith("--") and frag is None:
                frag = a
            else:
                raise IndexError(a)
        if (frag is None) == (b64 is None):
            raise IndexError("fragment")
    except IndexError:
        print("usage: merge_codex_config.py [--desktop] [--keep-on-error] "
              "(MANAGED_TOML | --fragment-b64 B64) [--current-file PATH]", file=sys.stderr)
        return 2
    raw = b""
    try:
        if cur_file is not None:
            p = Path(cur_file)
            raw = p.read_bytes() if p.exists() else b""
        else:
            raw = sys.stdin.buffer.read()
        current = raw.decode("utf-8-sig")
        managed = (base64.b64decode(b64) if b64 is not None else Path(frag).read_bytes()).decode("utf-8-sig")
        if desktop:
            managed = desktop_servers(managed)
        out = merge(current, managed)
    except Exception as e:  # noqa: BLE001 - every failure keeps the current file
        if not keep:
            raise
        print(f"warning: merging the managed Codex config failed ({e}); ~/.codex/config.toml left unchanged", file=sys.stderr)
        sys.stdout.buffer.write(raw)
        return 0
    sys.stdout.buffer.write(out.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
