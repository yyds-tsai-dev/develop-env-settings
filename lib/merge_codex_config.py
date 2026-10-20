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
its comments.
"""
import sys
from pathlib import Path

import tomlkit
from tomlkit.items import AoT, Table
from tomlkit.container import Container

WHOLESALE = ("mcp_servers",)


def _is_table(v):
    return isinstance(v, (Table, Container)) and not isinstance(v, AoT)


def _overlay(dst, src):
    for k, v in src.items():
        if _is_table(v) and k in dst and _is_table(dst[k]):
            _overlay(dst[k], v)
        else:
            dst[k] = v


def _check_timeouts(managed):
    for name, srv in (managed.get("mcp_servers") or {}).items():
        if "tool_timeout_sec" not in srv:
            raise ValueError(f"mcp_servers.{name}: tool_timeout_sec is required")


def merge(existing, managed):
    m = tomlkit.parse(managed)
    _check_timeouts(m)
    doc = tomlkit.parse(existing if existing.strip() else "")
    for k in WHOLESALE:
        if k in doc and k not in m:
            del doc[k]
    for k, v in m.items():
        if k in WHOLESALE:
            doc[k] = v
        elif _is_table(v) and k in doc and _is_table(doc[k]):
            _overlay(doc[k], v)
        else:
            doc[k] = v
    return tomlkit.dumps(doc)


def main(argv):
    if len(argv) != 2:
        print("usage: merge_codex_config.py MANAGED_TOML", file=sys.stderr)
        return 2
    sys.stdout.write(merge(sys.stdin.read(), Path(argv[1]).read_text()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
