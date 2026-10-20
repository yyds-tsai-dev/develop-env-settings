import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import resolve_versions as rv  # noqa: E402

MANIFEST = {
    "cli_tools": [{"name": "fzf", "source": "conda-forge:fzf"}],
    "uv_tools": [{"name": "semble", "source": "pypi:semble", "spec": "semble[mcp]"}],
    "node": {"major": 24},
    "mcp": [{"name": "mcp-drawio", "source": "npm:@next-ai-drawio/mcp-server"}],
    "claude": {
        "marketplaces": [{"name": "caveman", "source": "none"}],
        "plugins": [{"name": "caveman@caveman", "source": "none"}],
    },
    "installers": [{"name": "fnm", "source": "github:Schniz/fnm"}],
}


def test_resolves_each_source_kind():
    lock, warns = rv.resolve(MANIFEST, {}, lambda s: "1.2.3")
    assert lock == {"fzf": "1.2.3", "semble": "1.2.3", "mcp-drawio": "1.2.3", "fnm": "1.2.3"}
    assert warns == []


def test_failed_fetch_keeps_previous_value_and_warns():
    m = {"uv_tools": [{"name": "semble", "source": "pypi:semble"}]}
    lock, warns = rv.resolve(m, {"semble": "0.5.5"}, lambda s: None)
    assert lock == {"semble": "0.5.5"}
    assert len(warns) == 1 and "semble" in warns[0]


def test_failed_fetch_without_previous_value_omits_key_and_warns():
    m = {"uv_tools": [{"name": "semble", "source": "pypi:semble"}]}
    lock, warns = rv.resolve(m, {}, lambda s: None)
    assert "semble" not in lock
    assert len(warns) == 1 and "semble" in warns[0]


def test_github_tag_v_prefix_stripped():
    class R:
        status_code = 200

        def raise_for_status(self):
            pass

        def json(self):
            return {"tag_name": "v2.4.0"}

    class C:
        def get(self, url, **kw):
            assert url == "https://api.github.com/repos/Schniz/fnm/releases/latest"
            assert kw.get("timeout") == 10
            return R()

    assert rv.fetch_latest("github:Schniz/fnm", client=C()) == "2.4.0"


def test_only_limits_resolution():
    seen = []

    def fetch(s):
        seen.append(s)
        return "9.9"

    lock, _ = rv.resolve(MANIFEST, {"fzf": "0.1"}, fetch, only=["fnm"])
    assert seen == ["github:Schniz/fnm"]
    assert lock == {"fzf": "0.1", "fnm": "9.9"}


def test_lock_written_with_resolved_at_utc(tmp_path):
    mp, lp = tmp_path / "m.yaml", tmp_path / "v.yaml"
    mp.write_text(yaml.safe_dump(MANIFEST))
    lp.write_text("versions: {}\nresolved_at: null\n")
    rc = rv.main(["--manifest", str(mp), "--lock", str(lp)], fetch=lambda s: "1.2.3")
    assert rc == 0
    data = yaml.safe_load(lp.read_text())
    assert data["resolved_at"].endswith("Z") and "T" in data["resolved_at"]
    assert list(data["versions"]) == sorted(data["versions"])
    assert data["versions"]["fnm"] == "1.2.3"


def test_offline_skips_fetch(tmp_path):
    mp, lp = tmp_path / "m.yaml", tmp_path / "v.yaml"
    mp.write_text(yaml.safe_dump(MANIFEST))
    lp.write_text("versions: {fzf: '0.1'}\nresolved_at: null\n")

    def boom(s):
        raise AssertionError("network used")

    assert rv.main(["--manifest", str(mp), "--lock", str(lp), "--offline"], fetch=boom) == 0
    assert yaml.safe_load(lp.read_text())["versions"] == {"fzf": "0.1"}


def test_real_manifest_names_unique_and_node_major():
    m = yaml.safe_load((Path(__file__).resolve().parents[2] / "home/.chezmoidata/manifest.yaml").read_text())
    names = [e["name"] for e in rv.entries(m)]
    assert len(names) == len(set(names))
    assert m["node"] == {"major": 24}
    assert all(e["source"] == "none" or ":" in e["source"] for e in rv.entries(m))
