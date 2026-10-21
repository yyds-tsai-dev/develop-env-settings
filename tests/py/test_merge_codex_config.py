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


def test_url_server_kept_through_merge_and_safety_check():
    # a remote (URL) server: `url`, no command/args, its own tool_timeout_sec
    out = load(mcc.merge(LIVE, MANAGED))
    assert out["mcp_servers"]["openaiDeveloperDocs"] == {
        "url": "https://developers.openai.com/mcp",
        "tool_timeout_sec": 60,
    }
    # idempotent: merging into the merged file passes the check and changes nothing
    once = mcc.merge(LIVE, MANAGED)
    assert mcc.merge(once, MANAGED) == once


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


def test_dotted_mcp_key_does_not_capture_later_keys():
    src = ('mcp_servers.old.command = "x"\nservice_tier = "default"\n'
           '[projects."/p"]\ntrust_level = "trusted"\n')
    out = mcc.merge(src, MANAGED)
    got = load(out)
    assert got["service_tier"] == "default"
    assert got["projects"] == {"/p": {"trust_level": "trusted"}}
    assert got["mcp_servers"] == load(MANAGED)["mcp_servers"]
    assert mcc.merge(out, MANAGED) == out


def test_inline_table_merged_key_by_key():
    out = load(mcc.merge('tui = { status_line_use_colors = true }\n', MANAGED))
    assert out["tui"]["status_line_use_colors"] is True
    assert out["tui"]["status_line"] == load(MANAGED)["tui"]["status_line"]


def test_safety_check_trips_on_lost_key():
    good = mcc.merge(LIVE, MANAGED)
    mcc.check(LIVE, MANAGED, good)  # no error
    lost = good.replace('service_tier = "default"\n', "")
    try:
        mcc.check(LIVE, MANAGED, lost)
    except ValueError as e:
        assert "service_tier" in str(e)
    else:
        raise AssertionError("lost key not detected")
    moved = good.replace('service_tier = "default"\n', "") + '\n[tui.x]\nservice_tier = "default"\n'
    try:
        mcc.check(LIVE, MANAGED, moved)
    except ValueError:
        pass
    else:
        raise AssertionError("moved key not detected")
    wrong = good.replace('approvals_reviewer = "user"', 'approvals_reviewer = "x"')
    try:
        mcc.check(LIVE, MANAGED, wrong)
    except ValueError as e:
        assert "approvals_reviewer" in str(e)
    else:
        raise AssertionError("wrong managed value not detected")


def test_main_exits_nonzero_when_check_fails(tmp_path, monkeypatch, capsys):
    import io
    frag = tmp_path / "codex-managed.toml"
    frag.write_text(MANAGED)
    monkeypatch.setattr(mcc, "check", lambda *a: (_ for _ in ()).throw(ValueError("boom")))
    monkeypatch.setattr(sys, "stdin", io.StringIO(LIVE))
    try:
        rc = mcc.main(["merge_codex_config.py", str(frag)])
    except ValueError:
        rc = 1
    assert rc != 0
    assert capsys.readouterr().out == ""   # nothing half-written to stdout


def test_one_pass_fixpoint_for_hook_tables():
    for src in ('[hooks.state."/x/config.toml:session_start:0:0"]\ntrusted_hash = "sha256:00"\n',
                '[[hooks.PreToolUse]]\nmatcher = "*"\n\n[[hooks.PreToolUse.hooks]]\n'
                'type = "command"\ncommand = "x"\n',
                LIVE):
        once = mcc.merge(src, MANAGED)
        assert mcc.merge(once, MANAGED) == once
        assert "\n\n\n" not in once
        got = load(once)
        if "PreToolUse" in src:
            assert got["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "x"


# --desktop, --fragment-b64, --current-file, --keep-on-error

def test_desktop_drops_missing_commands_keeps_url_servers(capsys):
    have = {"uvx": "/x/uvx", "codebase-memory-mcp": "/x/codebase-memory-mcp"}
    out = load(mcc.desktop_servers(MANAGED, which=have.get, windows=False))
    assert set(out["mcp_servers"]) == {"semble", "codebase-memory-mcp", "openaiDeveloperDocs"}
    assert out["mcp_servers"]["openaiDeveloperDocs"]["tool_timeout_sec"] == 60
    assert all("tool_timeout_sec" in s for s in out["mcp_servers"].values())
    err = capsys.readouterr().err
    assert err.count("skipping Codex MCP server drawio") == 1
    # the result still merges and passes the safety check
    mcc.merge(LIVE, mcc.desktop_servers(MANAGED, which=have.get, windows=False))


def test_desktop_windows_shim_runs_through_cmd():
    have = {"uvx": r"C:\u\uvx.EXE", "codebase-memory-mcp": r"C:\u\codebase-memory-mcp.exe", "npx": r"C:\n\npx.CMD"}
    out = load(mcc.desktop_servers(MANAGED, which=have.get, windows=True))
    d = out["mcp_servers"]["drawio"]
    assert d["command"] == "cmd"
    assert d["args"] == ["/c", "npx", "-y", "@next-ai-drawio/mcp-server@0.4.6"]
    assert out["mcp_servers"]["semble"]["command"] == "uvx"   # a real .exe stays bare


def test_main_b64_current_file_desktop(tmp_path, monkeypatch, capsys):
    import base64
    cur = tmp_path / "config.toml"
    cur.write_bytes(LIVE.encode("utf-8"))
    monkeypatch.setattr(mcc.shutil, "which", lambda c: None)
    b64 = base64.b64encode(MANAGED.encode("utf-8")).decode()
    assert mcc.main(["m", "--desktop", "--keep-on-error", "--fragment-b64", b64, "--current-file", str(cur)]) == 0
    out = load(capsys.readouterr().out)
    assert set(out["mcp_servers"]) == {"openaiDeveloperDocs"}
    assert out["projects"] == load(LIVE)["projects"]
    # a missing current file is an empty config
    assert mcc.main(["m", "--fragment-b64", b64, "--current-file", str(tmp_path / "none.toml")]) == 0
    assert load(capsys.readouterr().out)["model"] == load(MANAGED)["model"]


def test_keep_on_error_prints_current_unchanged(tmp_path, capsys):
    import base64
    cur = tmp_path / "config.toml"
    cur.write_bytes(LIVE.encode("utf-8"))
    bad = base64.b64encode(b"[mcp_servers.x]\ncommand = \"y\"\n").decode()   # no tool_timeout_sec
    assert mcc.main(["m", "--keep-on-error", "--fragment-b64", bad, "--current-file", str(cur)]) == 0
    cap = capsys.readouterr()
    assert cap.out == LIVE
    assert "left unchanged" in cap.err
