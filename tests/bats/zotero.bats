#!/usr/bin/env bats
# bats file_tags=zotero
#
# Zotero: the zotero-mcp-server uv tool and zotero-cli skill (32-zotero), the
# pointer block in the managed ~/.codex/AGENTS.md, and the doctor checks.
# Stub uv and zotero-mcp; sandbox HOMEs under /tmp; the real $HOME is never
# touched. The Secret config is covered in secrets.bats; the real install in
# bootstrap.bats (Docker).

load helpers

SCRIPT=run_onchange_after_32-zotero.sh.tmpl
BEGIN='<!-- BEGIN zotero-cli skill (managed by `zotero-mcp install-skill`) -->'

setup() {
  new_sandbox
  STUB="$SB/stub"; mkdir -p "$STUB"
}
teardown() { chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"; }

lock() { sed -n "s/^  $1: *'\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$REPO_ROOT/home/.chezmoidata/versions.yaml"; }
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

render_script() {
  init_role server >&2
  chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/$SCRIPT" > "$SB/zotero.sh"
  echo "$SB/zotero.sh"
}

# fake_zotero VERSION: stub uv (tool list shows zotero-mcp-server vVERSION when
# $SB/installed exists; tool install creates it and logs to $SB/calls) and a stub
# zotero-mcp whose install-skill behaves like the real one: skill dir under
# <root>/.agents/skills/zotero-cli and a pointer block appended to <root>/AGENTS.md.
fake_zotero() {
  : > "$SB/calls"
  cat > "$STUB/uv" <<EOF
#!/bin/sh
echo "uv \$*" >> "$SB/calls"
case "\$1 \$2" in
  "tool list") [ -e "$SB/installed" ] && printf 'zotero-mcp-server v%s\n- zotero-cli\n- zotero-mcp\n' "\$(cat "$SB/installed")" ;;
  "tool install") v="\$(printf '%s\\n' "\$*" | sed -n 's/.*==//p')"; echo "\${v:-latest}" > "$SB/installed" ;;
esac
exit 0
EOF
  chmod +x "$STUB/uv"
  cat > "$STUB/zotero-mcp" <<EOF
#!/bin/sh
echo "zotero-mcp \$*" >> "$SB/calls"
[ "\$1" = install-skill ] || exit 0
root=; while [ \$# -gt 0 ]; do [ "\$1" = --root ] && root="\$2"; shift; done
d="\$root/.agents/skills/zotero-cli"; mkdir -p "\$d"
echo "skill \$(cat "$SB/installed")" > "\$d/SKILL.md"; echo ref > "\$d/reference.md"
printf '%s\n\nRead \`.agents/skills/zotero-cli/SKILL.md\`\n<!-- END zotero-cli skill -->\n' '$BEGIN' >> "\$root/AGENTS.md"
EOF
  chmod +x "$STUB/zotero-mcp"
}

run_script() { HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$1"; }

@test "managed Codex AGENTS.md has exactly one zotero-cli block, pointing at the skill Codex loads" {
  f="$REPO_ROOT/home/private_dot_codex/AGENTS.md"
  [ "$(grep -cF "$BEGIN" "$f")" -eq 1 ]
  [ "$(grep -cF '<!-- END zotero-cli skill -->' "$f")" -eq 1 ]
  grep -qF 'Read `~/.codex/skills/zotero-cli/SKILL.md` before using it.' "$f"
  ! grep -qE '/home/|/ldaphome|/Users/|\.agents/skills' "$f"
  # $BEGIN and the END marker are the ones zotero-mcp install-skill writes, so a
  # manual `install-skill --target agents --root ~/.codex` finds the block and
  # never appends a second one (it replaces it only with --force)
}

@test "install script: skill for Claude and Codex from a scratch root; managed AGENTS.md untouched; reruns stay single" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  sh -n "$f"
  grep -qx "# Locks: zotero-mcp-server=$(lock zotero-mcp-server)" "$f"
  fake_zotero
  mkdir -p "$SB_HOME/.codex"; cp "$REPO_ROOT/home/private_dot_codex/AGENTS.md" "$SB_HOME/.codex/AGENTS.md"
  before="$(sha256sum < "$SB_HOME/.codex/AGENTS.md")"
  run_script "$f"
  echo "$output"; cat "$SB/calls"
  [ "$status" -eq 0 ]
  grep -qx "uv tool install --quiet --python 3.12 zotero-mcp-server\[scite\]==$(lock zotero-mcp-server)" "$SB/calls"
  grep -q '^zotero-mcp install-skill --target agents --root /.* --force$' "$SB/calls"
  ! grep -q "root $SB_HOME" "$SB/calls"
  for d in .claude/skills/zotero-cli .codex/skills/zotero-cli; do
    [ -f "$SB_HOME/$d/SKILL.md" ] && [ -f "$SB_HOME/$d/reference.md" ]
  done
  [ ! -e "$SB_HOME/.codex/.agents" ]
  [ "$(sha256sum < "$SB_HOME/.codex/AGENTS.md")" = "$before" ]
  [ "$(grep -cF "$BEGIN" "$SB_HOME/.codex/AGENTS.md")" -eq 1 ]
  [ ! -e "$SB_HOME/.local/state/develop-env/retry/32-zotero" ]
  # installed at the lock: no reinstall; a new version's skill replaces the copies
  echo old > "$SB_HOME/.codex/skills/zotero-cli/SKILL.md"; echo old > "$SB_HOME/.claude/skills/zotero-cli/SKILL.md"
  echo 9.9.9 > "$SB/installed"; : > "$SB/calls"
  run_script "$f"
  [ "$status" -eq 0 ]
  grep -qx "uv tool install --quiet --python 3.12 zotero-mcp-server\[scite\]==$(lock zotero-mcp-server)" "$SB/calls"
  : > "$SB/calls"
  run_script "$f"
  ! grep -q 'tool install' "$SB/calls"
  grep -qx "skill $(lock zotero-mcp-server)" "$SB_HOME/.codex/skills/zotero-cli/SKILL.md"
  grep -qx "skill $(lock zotero-mcp-server)" "$SB_HOME/.claude/skills/zotero-cli/SKILL.md"
  [ "$(grep -cF "$BEGIN" "$SB_HOME/.codex/AGENTS.md")" -eq 1 ]
}

@test "install script failure leaves a retry marker" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  fake_zotero
  stub zotero-mcp 'exit 1'
  run_script "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zotero-mcp install-skill failed"* ]]
  [ -s "$SB_HOME/.local/state/develop-env/retry/32-zotero" ]
  [ ! -e "$SB_HOME/.claude/skills/zotero-cli" ]
}

@test "install script renders for every role and OS; the windows twin uses the same scratch-root install" {
  [ "$(uname -s)" = Linux ] || skip "renders on linux"
  init_role server >&2
  for os in linux darwin; do
    sed "s/\.chezmoi\.os/\"$os\"/g" "$REPO_ROOT/home/.chezmoiscripts/$SCRIPT" | chezmoi_iso execute-template > "$SB/z.sh"
    head -n1 "$SB/z.sh" | grep -q '^#!/bin/sh'
  done
  sed 's/\.chezmoi\.os/"windows"/g' "$REPO_ROOT/home/.chezmoiscripts/$SCRIPT" | chezmoi_iso execute-template > "$SB/z.sh"
  [ -z "$(tr -d '[:space:]' < "$SB/z.sh")" ]
  sed 's/\.chezmoi\.os/"windows"/g' "$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_32-zotero.ps1.tmpl" | chezmoi_iso execute-template > "$SB/z.ps1"
  grep -qF "\$zv = '$(lock zotero-mcp-server)'" "$SB/z.ps1"
  grep -qF "\$spec = 'zotero-mcp-server[scite]'" "$SB/z.ps1"
  grep -qF '& zotero-mcp install-skill --target agents --root $tmp --force' "$SB/z.ps1"
  grep -qF "(Join-Path \$HOME '.codex\\skills\\zotero-cli')" "$SB/z.ps1"
  ! grep -q 'mcp add' "$SB/z.ps1" "$SB/zotero.sh" 2>/dev/null
  sed 's/\.chezmoi\.os/"linux"/g' "$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_32-zotero.ps1.tmpl" | chezmoi_iso execute-template > "$SB/z.ps1"
  [ -z "$(tr -d '[:space:]' < "$SB/z.ps1")" ]
}

@test "doctor zotero: cli FAILs when missing, skills and config WARN, config SKIPs in --ci" {
  stub zotero-cli 'exit 0'
  for d in .claude/skills/zotero-cli .codex/skills/zotero-cli; do
    mkdir -p "$SB_HOME/$d"; : > "$SB_HOME/$d/SKILL.md"; : > "$SB_HOME/$d/reference.md"
  done
  doc() { DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='63-*' run "$REPO_ROOT/bin/doctor" "$@"; echo "$output"; }
  doc --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS zotero_cli"* ]] && [[ "$output" == *"PASS zotero_skills"* ]]
  [[ "$output" == *"SKIP zotero_config"* ]]
  doc
  [[ "$output" == *"WARN zotero_config: $SB_HOME/.config/zotero-mcp/config.json missing: create the Bitwarden item zotero (fields api_key, library_id)"* ]]
  rm -rf "$SB_HOME/.codex/skills/zotero-cli"
  doc --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN zotero_skills: zotero-cli skill missing: .codex/skills/zotero-cli"* ]]
  if ! command -v zotero-cli >/dev/null 2>&1; then
    rm -f "$STUB/zotero-cli"
    doc --ci
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL zotero_cli: zotero-cli not on PATH"* ]]
  fi
}
