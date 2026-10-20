# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml", "httpx"]
# ///
"""Resolve the Manifest to a Version lock (latest upstream version per entry)."""
import argparse
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

TIMEOUT = 10


def entries(manifest):
    """Yield every manifest entry that has a name (the lock key)."""
    claude = manifest.get("claude") or {}
    codex = manifest.get("codex") or {}
    groups = [
        manifest.get("cli_tools"), manifest.get("pdftools"), manifest.get("uv_tools"),
        manifest.get("mcp"), claude.get("marketplaces"), claude.get("plugins"),
        codex.get("skill_bundles"), manifest.get("installers"),
    ]
    return [e for g in groups for e in (g or [])]


def fetch_latest(source, client=None):
    """Latest version for `kind:ref`, or None on any network or parse failure."""
    try:
        if client is None:
            import httpx
            client = httpx
        kind, _, ref = source.partition(":")
        if kind == "pypi":
            url, pick = f"https://pypi.org/pypi/{ref}/json", lambda j: j["info"]["version"]
        elif kind == "npm":
            url, pick = f"https://registry.npmjs.org/{ref}", lambda j: j["dist-tags"]["latest"]
        elif kind == "github":
            url = f"https://api.github.com/repos/{ref}/releases/latest"
            # strip a leading "v" or a prefix such as "rust-v" up to the first digit
            pick = lambda j: re.sub(r"^\D*", "", j["tag_name"]) or j["tag_name"]  # noqa: E731
        elif kind == "conda-forge":
            url, pick = f"https://api.anaconda.org/package/conda-forge/{ref}", lambda j: j["latest_version"]
        else:
            return None
        headers = {}
        if kind == "github" and os.environ.get("GITHUB_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
        r = client.get(url, timeout=TIMEOUT, follow_redirects=True, headers=headers)
        r.raise_for_status()
        v = pick(r.json())
        return str(v) if v else None
    except Exception:
        return None


def resolve(manifest, old_lock, fetch, only=None):
    lock = dict(old_lock)
    warnings = []
    for e in entries(manifest):
        name, source = e["name"], e.get("source", "none")
        if source == "none" or (only and name not in only):
            continue
        v = fetch(source)
        if v is None:
            warnings.append(
                f"{name}: could not resolve {source}; "
                + (f"keeping {lock[name]}" if name in lock else "no previous value, omitted")
            )
        else:
            lock[name] = v
    return lock, warnings


def main(argv=None, fetch=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--lock", required=True)
    ap.add_argument("--only", nargs="+")
    ap.add_argument("--offline", action="store_true")
    a = ap.parse_args(argv)
    manifest = yaml.safe_load(Path(a.manifest).read_text()) or {}
    lp = Path(a.lock)
    old = (yaml.safe_load(lp.read_text()) or {}).get("versions") or {} if lp.exists() else {}
    if a.offline:
        lock, warns = dict(old), []
    else:
        lock, warns = resolve(manifest, old, fetch or fetch_latest, a.only)
    for w in warns:
        print(f"warning: {w}", file=sys.stderr)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lp.write_text(yaml.safe_dump(
        {"versions": dict(sorted(lock.items())), "resolved_at": stamp}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
