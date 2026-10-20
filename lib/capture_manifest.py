# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Capture non-file state of this machine into the repo (never commits, never touches versions.yaml).

Rewrites, from the current $HOME and PATH:
  - desktop/vscode/server-extensions.txt   from ~/.vscode-server/extensions
  - manifest claude.plugins / claude.marketplaces   from `claude plugin list` / `... marketplace list`
  - manifest uv_tools                      from `uv tool list`
  - manifest cli_tools / pdftools          from `micromamba env export --from-history`
Only manifest membership changes: entries are removed or appended as text lines, so comments,
ordering and every untouched line stay byte-identical. A source that is unavailable is skipped
(never treated as empty), so a missing tool cannot wipe a section.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "home/.chezmoidata/manifest.yaml"
EXT_LIST = ROOT / "desktop/vscode/server-extensions.txt"
PLATFORM = {"linux": "linux", "darwin": "darwin"}.get(sys.platform, "windows")

ITEM = re.compile(r'^(\s*)- \{ name: ("?)([^",}]+)\2\s*[,}]')


def note(msg):
    print(f"capture: {msg}")


def run(cmd):
    """stdout of cmd, or None when the command is missing or fails."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def sections(lines):
    """Yield (index, section id) for each line, id like 'cli_tools' or 'claude.plugins'."""
    top = sub = None
    for i, line in enumerate(lines):
        m = re.match(r"^(\w+):", line)
        if m:
            top, sub = m.group(1), None
        else:
            m = re.match(r"^  (\w+):", line)
            if m:
                sub = m.group(1)
        yield i, (f"{top}.{sub}" if top == "claude" and sub else top)


def sync(lines, section, wanted, new_line, keep):
    """Make the entries of `section` match `wanted` (set of names). Returns (lines, removed, added)."""
    idx = [(i, ITEM.match(l)) for (i, s), l in zip(sections(lines), lines) if s == section]
    idx = [(i, m) for i, m in idx if m]
    have = {m.group(3): i for i, m in idx}
    drop = {i for n, i in have.items() if n not in wanted and not keep(lines[i])}
    out = [l for i, l in enumerate(lines) if i not in drop]
    added = [n for n in sorted(wanted) if n not in have]
    if added and idx:
        last = idx[-1][0]
        indent = idx[-1][1].group(1)
        pos = last + 1 - len([i for i in drop if i <= last])
        out[pos:pos] = [indent + new_line(n) for n in added]
    elif added:
        note(f"{section}: no existing entries to anchor new ones; add by hand: {', '.join(added)}")
        added = []
    return out, sorted(n for n, i in have.items() if i in drop), added


def report(section, removed, added):
    if removed or added:
        note(f"{section}: -{len(removed)} +{len(added)}"
             + "".join(f"\n  - {n}" for n in removed) + "".join(f"\n  + {n}" for n in added))
    else:
        note(f"{section}: unchanged")


def applies(line):
    m = re.search(r"platforms:\s*\[([^\]]*)\]", line)
    return not m or PLATFORM in [p.strip() for p in m.group(1).split(",")]


def blocks(text):
    """Parse `claude plugin list`-style text into [(name, {Field: value})]."""
    out = []
    for line in text.splitlines():
        m = re.match(r"^\s*[❯>*•-]\s+(\S+)\s*$", line)
        if m:
            out.append((m.group(1), {}))
            continue
        m = re.match(r"^\s+([A-Za-z ]+):\s*(.*)$", line)
        if m and out:
            out[-1][1][m.group(1).strip()] = m.group(2).strip()
    return out


def main():
    lines = MANIFEST.read_text().split("\n")
    orig = list(lines)

    # VS Code server extensions
    ext_dir = Path.home() / ".vscode-server/extensions"
    if ext_dir.is_dir():
        ids = sorted({re.sub(r"-\d+\.\d+\.\d+.*$", "", d.name).lower()
                      for d in ext_dir.iterdir() if d.is_dir() and not d.name.startswith(".")})
        EXT_LIST.parent.mkdir(parents=True, exist_ok=True)
        EXT_LIST.write_text("".join(i + "\n" for i in ids))
        note(f"server-extensions.txt: {len(ids)} extensions")
    else:
        note(f"{ext_dir} not found: extension list unchanged")

    # Claude marketplaces and plugins
    out = run(["claude", "plugin", "marketplace", "list"])
    if out is None:
        note("claude marketplace list unavailable: claude.marketplaces unchanged")
    else:
        mk = blocks(out)
        repos = {}
        for n, f in mk:
            m = re.search(r"\(([\w.-]+/[\w.-]+)\)", f.get("Source", ""))
            repos[n] = m.group(1) if m else None
        names = {n for n, _ in mk}
        known = {m.group(3) for l in lines if (m := ITEM.match(l))}
        for n in sorted(names - known):
            if not repos[n]:
                note(f"claude.marketplaces: cannot read the repo of {n}; add it by hand")
                names.discard(n)
        lines, rem, add = sync(
            lines, "claude.marketplaces", names,
            lambda n: f"- {{ name: {n}, source: none, repo: {repos[n]} }}",
            keep=lambda l: "builtin: true" in l)
        report("claude.marketplaces", rem, add)
    out = run(["claude", "plugin", "list"])
    if out is None:
        note("claude plugin list unavailable: claude.plugins unchanged")
    else:
        names = {n for n, _ in blocks(out) if "@" in n}
        lines, rem, add = sync(
            lines, "claude.plugins", names,
            lambda n: f'- {{ name: "{n}", source: none, marketplace: {n.split("@", 1)[1]} }}',
            keep=lambda l: False)
        report("claude.plugins", rem, add)

    # uv tools
    out = run(["uv", "tool", "list"])
    if out is None:
        note("uv tool list unavailable: uv_tools unchanged")
    else:
        names = {m.group(1) for l in out.splitlines()
                 if (m := re.match(r"^([A-Za-z0-9][\w.-]*)\s+v?\d", l))}
        lines, rem, add = sync(
            lines, "uv_tools", names,
            lambda n: f'- {{ name: {n}, source: "pypi:{n}", spec: "{n}" }}',
            keep=lambda l: False)
        report("uv_tools", rem, add)

    # micromamba envs
    for section, env in (("cli_tools", "cli-tools"), ("pdftools", "pdftools")):
        out = run(["micromamba", "env", "export", "--from-history", "-n", env])
        if out is None:
            note(f"micromamba env {env} unavailable: {section} unchanged")
            continue
        names, in_deps = set(), False
        for l in out.splitlines():
            if re.match(r"^\w", l):
                in_deps = l.startswith("dependencies:")
            m = re.match(r"^\s*-\s+(?:[\w.-]+::)?([A-Za-z0-9][\w.+-]*)", l)
            if in_deps and m:
                names.add(m.group(1))
        names -= {"python", "pip"}
        lines, rem, add = sync(
            lines, section, names,
            lambda n: f'- {{ name: {n}, source: "conda-forge:{n}" }}',
            keep=lambda l: not applies(l))
        report(section, rem, add)

    if lines != orig:
        MANIFEST.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
