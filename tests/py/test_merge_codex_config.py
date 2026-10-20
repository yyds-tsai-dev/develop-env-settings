import sys
from pathlib import Path

import tomlkit

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import merge_codex_config as mcc  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures"
LIVE = (FIX / "codex_config.toml").read_text()      # today's config, home path replaced
MANAGED = (FIX / "codex_managed.toml").read_text()  # a rendered codex-managed.toml


def load(s):
    return tomlkit.parse(s).unwrap()


def test_project_trust_preserved():
    out = load(mcc.merge(LIVE, MANAGED))
    assert out["projects"]["/home/someone/project-a"] == {"trust_level": "trusted"}
    assert out["projects"]["/home/someone/project-b"] == {"trust_level": "trusted"}


def test_hooks_state_preserved():
    out = load(mcc.merge(LIVE, MANAGED))
    state = out["hooks"]["state"]
    assert state == load(LIVE)["hooks"]["state"]
    assert state["/home/someone/project-b/.codex/hooks.json:pre_tool_use:0:0"]["enabled"] is False
    # the managed hook events replace the installer's absolute-path ones
    for ev in ("SessionStart", "SubagentStart"):
        cmds = [h["command"] for g in out["hooks"][ev] for h in g["hooks"]]
        assert cmds == ["codebase-memory-mcp hook-augment"]


def test_mcp_servers_replaced_wholesale():
    out = load(mcc.merge(LIVE, MANAGED))
    m = load(MANAGED)
    assert out["mcp_servers"] == m["mcp_servers"]
    assert "graphify" not in out["mcp_servers"] and "paper-search" not in out["mcp_servers"]
    # a key only the old table had does not survive
    old = '[mcp_servers.semble]\ncommand = "/x/uvx"\nstartup_timeout_sec = 9\n'
    assert load(mcc.merge(old, MANAGED))["mcp_servers"]["semble"] == m["mcp_servers"]["semble"]


def test_unknown_top_level_key_preserved():
    out = load(mcc.merge(LIVE, MANAGED))
    assert out["service_tier"] == "default"
    assert out["model_auto_compact_token_limit"] == 400000
    assert out["marketplaces"]["openai-bundled"]["source_type"] == "local"
    assert out["plugins"]["visualize@openai-bundled"] == {"enabled": True}
    # nested keys beside a managed one survive
    assert out["tui"]["status_line_use_colors"] is True
    assert out["tui"]["screen_reader_detection_done"] is True
    assert out["tui"]["model_availability_nux"] == {"gpt-6-astra": 4}
    # managed values win
    assert out["model_reasoning_effort"] == "medium"
    assert out["tui"]["status_line"] == load(MANAGED)["tui"]["status_line"]


def test_every_mcp_server_has_tool_timeout_sec():
    out = load(mcc.merge(LIVE, MANAGED))
    assert out["mcp_servers"]
    for name, srv in out["mcp_servers"].items():
        assert isinstance(srv.get("tool_timeout_sec"), int), name
    # a fragment that forgets it is refused
    bad = '[mcp_servers.x]\ncommand = "x"\n'
    try:
        mcc.merge(LIVE, bad)
    except ValueError as e:
        assert "tool_timeout_sec" in str(e)
    else:
        raise AssertionError("missing tool_timeout_sec accepted")


def test_idempotent():
    for start in (LIVE, "", "model = \"x\"\n"):
        once = mcc.merge(start, MANAGED)
        assert mcc.merge(once, MANAGED) == once  # byte for byte


def test_comments_preserved():
    src = LIVE.replace("service_tier = \"default\"", "# keep me\nservice_tier = \"default\"  # and me")
    out = mcc.merge(src, MANAGED)
    assert "# keep me" in out and "# and me" in out


def test_empty_existing():
    out = mcc.merge("", MANAGED)
    assert load(out) == load(MANAGED)
    assert mcc.merge("\n", MANAGED) == out


def test_main_reads_stdin_writes_stdout(tmp_path, monkeypatch, capsys):
    import io
    frag = tmp_path / "codex-managed.toml"
    frag.write_text(MANAGED)
    monkeypatch.setattr(sys, "stdin", io.StringIO(LIVE))
    assert mcc.main(["merge_codex_config.py", str(frag)]) == 0
    assert capsys.readouterr().out == mcc.merge(LIVE, MANAGED)
