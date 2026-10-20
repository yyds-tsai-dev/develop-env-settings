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


_CONDA_VERSION = re.compile(r"^\d+(\.\d+)*[a-z]?\d*_?$")


def _conda_key(v):
    m = re.match(r"^(\d+(?:\.\d+)*)([a-z]?)(\d*)_?$", v)
    return (tuple(int(x) for x in m.group(1).split(".")), m.group(2), int(m.group(3) or 0))


def _conda_pick(j):
    vs = {f["version"] for f in j["files"]
          if f.get("attrs", {}).get("subdir") in ("linux-64", "noarch")
          and _CONDA_VERSION.match(f["version"])}
    return max(vs, key=_conda_key) if vs else None


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
            ref, _, prefix = ref.partition("|")  # "owner/repo|<tag_prefix>"; undeclared: optional "v"
            url = f"https://api.github.com/repos/{ref}/releases/latest"

            def pick(j):
                tag = j["tag_name"]
                if not prefix:
                    return tag[1:] if tag.startswith("v") else tag
                if not tag.startswith(prefix):
                    raise ValueError(f"tag {tag} lacks prefix {prefix}")
                return tag[len(prefix):]
        elif kind == "conda-forge":
            # latest_version can be a non-installable string; take the highest valid version
            # that has a real linux-64 or noarch build
            url, pick = f"https://api.anaconda.org/package/conda-forge/{ref}", _conda_pick
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
    ents = entries(manifest)
    if only:
        for n in only:
            if n not in {e["name"] for e in ents}:
                warnings.append(f"--only {n}: not in manifest")
    else:
        names = {e["name"] for e in ents}
        lock = {k: v for k, v in lock.items() if k in names}
    for e in ents:
        name, source = e["name"], e.get("source", "none")
        if source == "none" or (only and name not in only):
            continue
        if source.startswith("github:") and e.get("tag_prefix"):
            source = f"{source}|{e['tag_prefix']}"
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
    tmp = lp.with_name(lp.name + ".tmp")
    tmp.write_text(yaml.safe_dump(
        {"versions": dict(sorted(lock.items())), "resolved_at": stamp}, sort_keys=True))
    os.replace(tmp, lp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
