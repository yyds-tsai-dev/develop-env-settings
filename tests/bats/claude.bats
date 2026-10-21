#!/usr/bin/env bats
# bats file_tags=claude
#
# Claude Code: user CLAUDE.md, generic agents, settings.json, the install script
# (plugins, MCP, skills, codebase-memory-mcp) and its doctor checks. Host tests
# render into sandboxes under /tmp and use a stub `claude`; the last test runs
# the real thing in Docker (tests/docker/Dockerfile.server). The real $HOME is
# never read or written, and no real `claude` command runs on the host.

load helpers

SCRIPT=run_onchange_after_50-claude.sh.tmpl

setup() {
  new_sandbox
  STUB="$SB/stub"; mkdir -p "$STUB"
}
teardown() { chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"; }

MANIFEST() { echo "$REPO_ROOT/home/.chezmoidata/manifest.yaml"; }

# lock KEY: the Version lock value for KEY.
lock() { sed -n "s/^  $1: *'\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$REPO_ROOT/home/.chezmoidata/versions.yaml"; }

# manifest_plugins / manifest_mkts: names from the manifest's claude section.
manifest_plugins() { sed -n 's/^ *- { name: "\([^"]*@[^"]*\)".*/\1/p' "$(MANIFEST)"; }
manifest_mkts() {
  awk '/^  marketplaces:/ { s = 1; next } /^  [a-z_]+:/ { s = 0 }
       s && match($0, /name: *[^,} ]+/) { v = substr($0, RSTART, RLENGTH); sub(/name: */, "", v); print v }' "$(MANIFEST)"
}

json_ok() {
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
  elif command -v python >/dev/null 2>&1; then python -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
  else jq -e . "$1" >/dev/null; fi
}

render_script() {
  init_role "${1:-server}" >&2
  chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/$SCRIPT" > "$SB/claude.sh"
  echo "$SB/claude.sh"
}

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

@test "settings.json renders valid JSON with every manifest plugin enabled" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  run render_home server
  [ "$status" -eq 0 ]
  dest="${lines[${#lines[@]}-1]}"
  f="$dest/.claude/settings.json"
  [ -f "$f" ]
  json_ok "$f"
  n=0
  for p in $(manifest_plugins); do
    grep -qF "\"$p\": true" "$f" || { echo "plugin $p not enabled"; false; }
    n=$((n + 1))
  done
  [ "$n" -ge 7 ]
  for m in $(manifest_mkts); do
    [ "$m" = claude-plugins-official ] && continue   # builtin: not declared
    grep -qF "\"$m\": {" "$f" || { echo "marketplace $m missing"; false; }
  done
  ! grep -qF '"claude-plugins-official": {' "$f"
  grep -qF '"repo": "JuliusBrussee/caveman"' "$f"
  # hooks use $HOME, never an absolute path; no statusline release locked and no
  # binary: no statusLine (Claude would run a missing command)
  grep -qF '"command": "\"$HOME/.claude/hooks/cbm-code-discovery-gate\""' "$f"
  if [ -z "$(lock statusline)" ]; then ! grep -q statusLine "$f"; fi
  ! grep -qE '/home/|/ldaphome|/Users/' "$f"
}

@test "statusLine renders once a statusline release is locked or the binary exists" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  init_role server >&2
  t='{{ template "claude-settings.json" . }}'
  run chezmoi_iso execute-template "{{ \$_ := unset .versions \"statusline\" }}$t"
  [ "$status" -eq 0 ]
  [[ "$output" != *statusLine* ]]
  printf '%s\n' "$output" > "$SB/none.json"; json_ok "$SB/none.json"
  run chezmoi_iso execute-template "{{ \$_ := set .versions \"statusline\" \"1.0.0\" }}$t"
  [[ "$output" == *'"command": "\"$HOME/.claude/statusline-bin\""'* ]]
  printf '%s\n' "$output" > "$SB/lock.json"; json_ok "$SB/lock.json"
  mkdir -p "$SB_HOME/.claude"; : > "$SB_HOME/.claude/statusline-bin"   # a local build
  run chezmoi_iso execute-template "{{ \$_ := unset .versions \"statusline\" }}$t"
  [[ "$output" == *'"command": "\"$HOME/.claude/statusline-bin\""'* ]]
  printf '%s\n' "$output" > "$SB/built.json"; json_ok "$SB/built.json"
}

# init_plain_desktop: a plain desktop config (on Linux, where the desktop role
# is refused, a server config with its data rewritten to the desktop role).
init_plain_desktop() {
  if [ "$(uname -s)" = Linux ]; then
    init_role server >&2
    sed -e 's/^\( *role = \).*/\1"desktop"/' -e 's/^\( *isServer = \).*/\1false/' \
        -e 's/^\( *isDesktop = \).*/\1true/' "$SB_CONFIG" > "$SB/cfg.new"
    cat "$SB/cfg.new" > "$SB_CONFIG"
  else
    init_role desktop >&2
  fi
}

# render_os OS SCRIPT: SCRIPT rendered with .chezmoi.os replaced by OS.
render_os() {
  sed "s/\.chezmoi\.os/\"$1\"/g" "$REPO_ROOT/home/.chezmoiscripts/$2" | chezmoi_iso execute-template
}

# sys_path: $SB/sys holding links to the basic system tools only, so a test
# PATH ($STUB:$SB/sys) has no npx, uvx, graphify or claude from the host.
sys_path() {
  local t p
  mkdir -p "$SB/sys"
  for t in sh bash env awk sed grep cat cp mv rm mkdir mktemp cmp chmod tr head tail \
           date dirname basename uname printf ls touch sort cut wc tee id find xargs; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$SB/sys/$t"
  done
  echo "$SB/sys"
}

blank() { [ -z "$(tr -d '[:space:]' <<<"$1")" ]; }

@test "plain desktop gets Claude Code but no Codex: scripts render per OS, ~/.claude managed" {
  init_plain_desktop
  # macOS: the sh scripts; Windows: the ps1 twins; Codex nowhere
  for s in "$SCRIPT" run_onchange_after_60-statusline.sh.tmpl; do
    out="$(render_os darwin "$s")"; ! blank "$out" || { echo "$s empty on a macOS desktop"; false; }
    out="$(render_os windows "$s")"; blank "$out" || { echo "$s renders on windows"; false; }
  done
  for s in run_onchange_after_50-claude.ps1.tmpl run_onchange_after_60-statusline.ps1.tmpl; do
    out="$(render_os windows "$s")"; ! blank "$out" || { echo "$s empty on a windows desktop"; false; }
    out="$(render_os darwin "$s")"; blank "$out" || { echo "$s renders on macOS"; false; }
  done
  for o in darwin windows; do
    out="$(render_os "$o" run_onchange_after_55-codex.sh.tmpl)"; blank "$out" || { echo "codex renders on a $o desktop"; false; }
  done
  run chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiignore"
  for p in .codex .config/paper-search-mcp; do printf '%s\n' "$output" | grep -qx "$p"; done
  ! printf '%s\n' "$output" | grep -qx '.claude'
}

@test "windows install script: native installer, cbm for Claude only, MCP servers guarded by runtime" {
  init_plain_desktop
  render_os windows run_onchange_after_50-claude.ps1.tmpl > "$SB/claude.ps1"
  f="$SB/claude.ps1"
  grep -qF "Get-Script 'https://claude.ai/install.ps1'" "$f"
  grep -qF -- '-File $inst "--dir=$bin" --skip-config' "$f"
  grep -qF -- 'install -y --skip-binary --clients=claude "--dir=$bin"' "$f"
  grep -qF "\$cbmVersion = '$(lock codebase-memory-mcp)'" "$f"
  grep -qF "\$cl = @('uvx', '--python', '3.12', '--from', 'semble[mcp]==$(lock mcp-semble)', 'semble')" "$f"
  grep -qF "Set-McpServer 'semble' \$cl" "$f"
  [ "$(grep -c '^        \$cl = Get-McpCommandLine \$cl$' "$f")" -eq 3 ]
  [ "$(grep -c '^        Invoke-Prewarm help \$cl$' "$f")" -eq 1 ]    # uvx (semble)
  [ "$(grep -c '^        Invoke-Prewarm stdin \$cl$' "$f")" -eq 1 ]   # npx (drawio)
  grep -qF 'try { $p.StandardInput.Close() } catch { }' "$f"
  grep -qF "if (\$src -match '\.(cmd|bat|ps1)\$') { return @('cmd', '/c') + \$CommandLine }" "$f"
  for c in uvx codebase-memory-mcp npx; do
    grep -qF "if (-not (Test-Cmd '$c')) {" "$f" || { echo "no runtime guard for $c"; false; }
  done
  ! grep -qE "Set-McpServer '(graphify|paper-search)'" "$f"   # codex-only servers
  grep -qF "Skip-Step 'graphify not installed on this desktop; skipping the graphify skill'" "$f"
  for p in $(manifest_plugins); do grep -qF "& claude plugin install '$p'" "$f"; done
  grep -q '^# retry: $' "$f"
  grep -q 'Set-RetryMarker' "$f"
  ! grep -qiE 'login|setup-token' "$f"
  ! grep -qE '/home/|/ldaphome|/Users/|C:\\Users' "$f"
}

@test "plain desktop install script: only MCP servers whose command exists, skips are not failures" {
  [ "$(uname -s)" = Linux ] || skip "stub-only PATH needs a linux host"
  sys="$(sys_path)"
  init_plain_desktop
  render_os darwin "$SCRIPT" > "$SB/claude.sh"
  sh -n "$SB/claude.sh"
  grep -qF "if ! command -v 'npx' >/dev/null 2>&1; then" "$SB/claude.sh"
  fake_claude
  rm -f "$STUB/graphify" "$STUB/npx"   # no uv tools on a plain desktop; no npx here
  stub uvx "echo \"uvx \$*\" >> '$SB/calls'"   # uv comes with Bootstrap; npx is missing here
  HOME="$SB_HOME" PATH="$STUB:$sys" run sh "$SB/claude.sh"
  echo "$output"; cat "$SB/calls"
  [ "$status" -eq 0 ]
  grep -q '^mcp add -s user semble -- uvx ' "$SB/calls"
  grep -qx 'mcp add -s user codebase-memory-mcp -- codebase-memory-mcp' "$SB/calls"
  ! grep -q 'mcp add -s user drawio' "$SB/calls"
  [ "$(grep -c 'npx not found on this desktop; skipping MCP server drawio' <<<"$output")" -eq 1 ]
  [ "$(grep -c 'skipping the graphify skill' <<<"$output")" -eq 1 ]
  [ ! -e "$SB_HOME/.local/state/develop-env/retry/50-claude" ]   # a skip is not a failure
  for p in $(manifest_plugins); do grep -qx "plugin install $p" "$SB/calls"; done
  json_ok "$SB_HOME/.claude/settings.json"
  # semble's uvx command was pre-warmed once, before it was registered
  [ "$(grep -cx "uvx --python 3.12 --from semble\[mcp\]==$(lock mcp-semble) semble --help" "$SB/calls")" -eq 1 ]
  [ "$(grep -n 'semble --help' "$SB/calls" | cut -d: -f1)" -lt "$(grep -n '^mcp add -s user semble' "$SB/calls" | cut -d: -f1)" ]
  # with npx on PATH, drawio is pre-warmed and registered too
  stub npx "echo \"npx \$*\" >> '$SB/calls'"
  : > "$SB/calls"
  HOME="$SB_HOME" PATH="$STUB:$sys" run sh "$SB/claude.sh"
  [ "$status" -eq 0 ]
  grep -qx "npx -y @next-ai-drawio/mcp-server@$(lock mcp-drawio)" "$SB/calls"
  grep -qx "mcp add -s user drawio -- npx -y @next-ai-drawio/mcp-server@$(lock mcp-drawio)" "$SB/calls"
  [ ! -e "$SB_HOME/.local/state/develop-env/retry/50-claude" ]
  # a failed pre-warm is a failure: warning and retry marker
  stub uvx 'exit 1'
  HOME="$SB_HOME" PATH="$STUB:$sys" run sh "$SB/claude.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not pre-fetch the MCP server command: uvx"* ]]
  [ -s "$SB_HOME/.local/state/develop-env/retry/50-claude" ]
}

@test "server install script has no desktop runtime guards" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  ! grep -q 'not found on this desktop' "$f"
  ! grep -q 'not installed on this desktop' "$f"
  ! grep -q 'prewarm' "$f"
  ! grep -q 'A plain Desktop' "$f"
  grep -qF 'warn "graphify missing; skipping the graphify skill"' "$f"
}

@test "doctor on a plain desktop expects only the MCP servers and installer skills present there" {
  [ "$(uname -s)" = Linux ] || skip "stub-only PATH needs a linux host"
  sys="$(sys_path)"
  fake_claude
  rm -f "$STUB/graphify" "$STUB/codebase-memory-mcp" "$STUB/npx"
  stub uvx 'exit 0'
  for p in $(manifest_plugins); do printf '{"id": "%s"}\n' "$p"; done > "$SB/plugins.json"
  cat > "$STUB/claude" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "--version "*) echo "9.9.9 (Claude Code)" ;;
  "plugin list") cat "$SB/plugins.json" ;;
  "mcp list") cat "$SB/mcplist" ;;
  "auth status") exit 1 ;;
esac
EOF
  printf 'semble: uvx - \342\234\224 Connected\n' > "$SB/mcplist"
  for s in find-skills paper-search; do
    mkdir -p "$SB_HOME/.claude/skills/$s"; : > "$SB_HOME/.claude/skills/$s/SKILL.md"
  done
  DEVENV_ROLE=desktop HOME="$SB_HOME" PATH="$STUB:$sys" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [ "$status" -eq 0 ]
  for c in claude_installed claude_plugins claude_mcp claude_skills; do [[ "$output" == *"PASS $c"* ]]; done
  [[ "$output" == *"WARN statusline_installed"* ]]
  [[ "$output" == *"SKIP claude_login: login check skipped in --ci"* ]]
  [[ "$output" != *"server role only"* ]]
  # once codebase-memory-mcp is installed, its server and skill are expected
  stub codebase-memory-mcp 'exit 0'
  DEVENV_ROLE=desktop HOME="$SB_HOME" PATH="$STUB:$sys" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL claude_mcp: MCP server(s) not registered: codebase-memory-mcp:"* ]]
  [[ "$output" == *"FAIL claude_skills: skill(s) missing from ~/.claude/skills: codebase-memory:"* ]]
  [[ "$output" != *"drawio"* ]]
  # a server role expects every server and skill whatever is on PATH
  DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$sys" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [[ "$output" == *"not registered: codebase-memory-mcp drawio:"* ]]
  [[ "$output" == *"missing from ~/.claude/skills: graphify codebase-memory:"* ]]
}

@test "install script leaves a retry marker on failure and removes it after a clean run" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  grep -q '^# retry: $' "$f"
  m="$SB_HOME/.local/state/develop-env/retry/50-claude"
  stub curl 'exit 22'
  stub codebase-memory-mcp "echo 'codebase-memory-mcp $(lock codebase-memory-mcp)'"
  run_script "$f"
  [ "$status" -eq 0 ]
  n1="$(cat "$m")"; [ -n "$n1" ]
  [[ "$output" == *"bin/update"* ]]
  # the next render shows the nonce, so chezmoi reruns the script
  HOME="$SB_HOME" chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/$SCRIPT" > "$SB/again.sh"
  grep -qxF "# retry: $n1" "$SB/again.sh"
  # a second failure writes a new nonce, so the render changes again
  run_script "$SB/again.sh"
  n2="$(cat "$m")"; [ -n "$n2" ] && [ "$n2" != "$n1" ]
  HOME="$SB_HOME" chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/$SCRIPT" > "$SB/again.sh"
  grep -qxF "# retry: $n2" "$SB/again.sh"
  # a clean run (everything present) removes the marker
  fake_claude
  for p in $(manifest_plugins); do printf '  {\n    "id": "%s"\n  },\n' "$p"; done > "$SB/plugins.json"
  for m2 in $(manifest_mkts); do printf '  {\n    "name": "%s"\n  },\n' "$m2"; done > "$SB/mkts.json"
  run_script "$SB/again.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$m" ]
}

@test "generic CLAUDE.md and agents mention no project nouns" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  run render_home server
  [ "$status" -eq 0 ]
  dest="${lines[${#lines[@]}-1]}"
  for a in deep-reasoner worker fast-worker semble-search researcher; do
    [ -s "$dest/.claude/agents/$a.md" ] || { echo "agent $a missing"; false; }
  done
  [ -s "$dest/.claude/CLAUDE.md" ]
  run grep -niE 'DREAMPlace|placer|hMETIS|evaluator_gpu|env\.sh|IO-Aware' \
    "$dest/.claude/CLAUDE.md" "$dest"/.claude/agents/*.md
  [ "$status" -eq 1 ]
  c="$dest/.claude/CLAUDE.md"
  for s in '## Timezone' '## graphify' '## Semble Code Search' '## Advisor' '## Agent orchestration'; do
    grep -qF "$s" "$c" || { echo "section $s missing"; false; }
  done
  grep -q '\.claude/agents/<role>\.md.*overrides' "$c"
  grep -qF 'Blocked on me' "$c"
  grep -qi 'codex' "$c"
  # model and effort frontmatter kept from the project files
  grep -qx 'model: opus' "$dest/.claude/agents/deep-reasoner.md"
  grep -qx 'model: opus' "$dest/.claude/agents/worker.md"
  grep -qx 'effort: medium' "$dest/.claude/agents/worker.md"
  grep -qx 'model: sonnet' "$dest/.claude/agents/fast-worker.md"
  # semble pin follows the Version lock
  grep -qF "uvx --python 3.12 --from \"semble[mcp]==$(lock semble)\"" "$c"
  grep -qF "semble[mcp]==$(lock semble)" "$dest/.claude/agents/semble-search.md"
}

@test "mcp add commands use locked versions and bare commands" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  [ -s "$f" ]
  head -n1 "$f" | grep -q '^#!/bin/sh'
  sh -n "$f"
  grep -qF "semble[mcp]==$(lock mcp-semble)" "$f"
  grep -qF "@next-ai-drawio/mcp-server@$(lock mcp-drawio)" "$f"
  grep -qE "^mcp_server 'semble' 'uvx' '--python' '3.12' '--from' " "$f"
  grep -qE "^mcp_server 'drawio' 'npx' " "$f"
  grep -qE "^mcp_server 'codebase-memory-mcp' 'codebase-memory-mcp'$" "$f"
  ! grep -qE "^mcp_server '(graphify|paper-search)'" "$f"   # codex-only servers
  run grep -nE '/(uvx|npx)\b' "$f"
  [ "$status" -eq 1 ]
  # pinned upstreams: codebase-memory-mcp installer and the reinstalled skills
  grep -qF "CBM_VERSION=\"$(lock codebase-memory-mcp)\"" "$f"
  grep -qF "vercel-labs/skills/v$(lock skill-find-skills)/skills/find-skills/SKILL.md" "$f"
  grep -qF "openags/paper-search-mcp/v$(lock paper-search-mcp)/claude-code/SKILL.md" "$f"
}

@test "install script re-applies the exact rendered settings.json" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  run render_home server
  dest="${lines[${#lines[@]}-1]}"
  sed -n "/^cat > \"\$want\" <<'DEVENV_CLAUDE_SETTINGS'\$/,/^DEVENV_CLAUDE_SETTINGS\$/p" "$f" \
    | sed '1d;$d' > "$SB/heredoc.json"
  cmp "$SB/heredoc.json" "$dest/.claude/settings.json"
}

# fake_claude: a stub `claude` that logs every call to $SB/calls and answers
# `mcp get` from $SB/mcp/<name> (Command/Args lines), `plugin list --json` and
# `plugin marketplace list --json` from $SB/plugins.json and $SB/mkts.json.
fake_claude() {
  mkdir -p "$SB/mcp"; : > "$SB/calls"
  echo '[]' > "$SB/plugins.json"; echo '[]' > "$SB/mkts.json"
  cat > "$STUB/claude" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/calls"
case "\$1 \$2" in
  "--version "*) echo "9.9.9 (Claude Code)" ;;
  "mcp get") [ -f "$SB/mcp/\$3" ] || exit 1; cat "$SB/mcp/\$3" ;;
  "plugin list") cat "$SB/plugins.json" ;;
  "plugin marketplace") [ "\$3" = list ] && cat "$SB/mkts.json" ;;
esac
exit 0
EOF
  chmod +x "$STUB/claude"
  stub codebase-memory-mcp "echo 'codebase-memory-mcp $(lock codebase-memory-mcp)'"
  # graphify install: writes its skill under $CLAUDE_CONFIG_DIR (and a CLAUDE.md block)
  stub graphify 'mkdir -p "$CLAUDE_CONFIG_DIR/skills/graphify" && echo graphify > "$CLAUDE_CONFIG_DIR/skills/graphify/SKILL.md" && echo "# graphify" > "$CLAUDE_CONFIG_DIR/CLAUDE.md"'
  # npx: the drawio pre-warm start (never the host's npx)
  stub npx "echo \"npx \$*\" >> '$SB/calls'"
  # curl -fsSL --retry 3 -o FILE URL: write a fake skill
  stub curl 'while [ $# -gt 1 ]; do [ "$1" = -o ] && { echo "skill from $3" > "$2"; exit 0; }; shift; done; exit 1'
}

run_script() {
  HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$1"
}

@test "install script registers missing MCP servers and leaves matching ones alone" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  fake_claude
  # semble already registered with the locked command; drawio with a stale one
  printf '  Command: uvx\n  Args: --python 3.12 --from semble[mcp]==%s semble\n' "$(lock mcp-semble)" > "$SB/mcp/semble"
  printf '  Command: npx\n  Args: -y @next-ai-drawio/mcp-server@latest\n' > "$SB/mcp/drawio"
  run_script "$f"
  echo "$output"; cat "$SB/calls"
  [ "$status" -eq 0 ]
  ! grep -q 'mcp remove -s user semble' "$SB/calls"
  ! grep -q 'mcp add -s user semble' "$SB/calls"
  grep -qx 'mcp remove -s user drawio' "$SB/calls"
  grep -qx "mcp add -s user drawio -- npx -y @next-ai-drawio/mcp-server@$(lock mcp-drawio)" "$SB/calls"
  # drawio is started once (npx caches it) before it is registered; semble is not pre-warmed on a server
  [ "$(grep -n "^npx -y @next-ai-drawio/mcp-server@$(lock mcp-drawio)\$" "$SB/calls" | cut -d: -f1)" -lt "$(grep -n '^mcp add -s user drawio' "$SB/calls" | cut -d: -f1)" ]
  ! grep -q -- '--help' "$SB/calls"
  ! grep -q 'mcp remove -s user codebase-memory-mcp' "$SB/calls"   # not registered yet
  grep -qx 'mcp add -s user codebase-memory-mcp -- codebase-memory-mcp' "$SB/calls"
  # every plugin and marketplace is added; nothing logs in
  for p in $(manifest_plugins); do grep -qx "plugin install $p" "$SB/calls"; done
  grep -qx 'plugin marketplace add anthropics/claude-plugins-official' "$SB/calls"
  ! grep -qE '^(auth|login|setup-token)' "$SB/calls"
  # skills fetched; settings.json written
  grep -q 'vercel-labs/skills' "$SB_HOME/.claude/skills/find-skills/SKILL.md"
  grep -q 'openags/paper-search-mcp' "$SB_HOME/.claude/skills/paper-search/SKILL.md"
  [ -s "$SB_HOME/.claude/skills/graphify/SKILL.md" ]
  [ ! -e "$SB_HOME/.claude/CLAUDE.md" ]   # graphify never edits the managed CLAUDE.md
  json_ok "$SB_HOME/.claude/settings.json"
}

@test "install script skips installed plugins and marketplaces" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  fake_claude
  { echo '['; for p in $(manifest_plugins); do printf '  {\n    "id": "%s",\n    "scope": "user"\n  },\n' "$p"; done; echo ']'; } > "$SB/plugins.json"
  { echo '['; for m in $(manifest_mkts); do printf '  {\n    "name": "%s"\n  },\n' "$m"; done; echo ']'; } > "$SB/mkts.json"
  run_script "$f"
  [ "$status" -eq 0 ]
  ! grep -q '^plugin install' "$SB/calls"
  ! grep -q '^plugin marketplace add' "$SB/calls"
}

@test "install script warns and exits 0 when claude cannot be installed" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render_script)"
  stub curl 'exit 22'
  stub codebase-memory-mcp "echo 'codebase-memory-mcp $(lock codebase-memory-mcp)'"
  run_script "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning:"*"claude"* ]]
  json_ok "$SB_HOME/.claude/settings.json"   # settings still applied
}

@test "doctor claude checks: pass with everything present and connected, login skips in --ci" {
  fake_claude
  for p in $(manifest_plugins); do printf '{"id": "%s"}\n' "$p"; done > "$SB/plugins.json"
  cat > "$STUB/claude" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "--version "*) echo "9.9.9 (Claude Code)" ;;
  "plugin list") cat "$SB/plugins.json" ;;
  "mcp list") cat "$SB/mcplist" ;;
  "auth status") exit 1 ;;
esac
EOF
  printf 'semble: uvx - \342\234\224 Connected\ncodebase-memory-mcp: codebase-memory-mcp  - \342\234\224 Connected\ndrawio: npx - \342\234\224 Connected\n' > "$SB/mcplist"
  for s in find-skills paper-search graphify codebase-memory; do
    mkdir -p "$SB_HOME/.claude/skills/$s"; : > "$SB_HOME/.claude/skills/$s/SKILL.md"
  done
  DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [ "$status" -eq 0 ]
  for c in claude_installed claude_plugins claude_mcp claude_skills; do
    [[ "$output" == *"PASS $c"* ]]
  done
  [[ "$output" == *"SKIP claude_login"* ]]
  # outside --ci, a missing login and a missing plugin FAIL
  echo '[]' > "$SB/plugins.json"
  DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL claude_login"* ]]
  [[ "$output" == *"FAIL claude_plugins"* ]]
  # a missing plugin FAILs in --ci too
  DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL claude_plugins"* ]]
  # a registered server that fails its health check FAILs
  printf 'semble: uvx - \342\234\230 Failed to connect\ncodebase-memory-mcp: codebase-memory-mcp  - \342\234\224 Connected\ndrawio: npx - \342\234\224 Connected\n' > "$SB/mcplist"
  DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [[ "$output" == *"FAIL claude_mcp: MCP server(s) not connecting: semble"*": run chezmoi state delete-bucket --bucket=entryState && $REPO_ROOT/bin/update"* ]]
  # an unregistered one FAILs
  grep -v '^drawio:' "$SB/mcplist" > "$SB/m2"; mv "$SB/m2" "$SB/mcplist"
  DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"not registered: drawio: run $REPO_ROOT/bin/update (or re-run bootstrap)"* ]]
}

# bats test_tags=docker
@test "claude install in container: doctor claude checks PASS or SKIP(login)" {
  [ "$(uname -s)" = Linux ] || skip "docker runs on linux hosts only"
  [ -z "${DEVENV_SKIP_DOCKER:-}" ] || skip "DEVENV_SKIP_DOCKER is set (CI runs this in its docker step)"
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  img=devenv-server-test
  docker build -q -t "$img" --build-arg UID="$(id -u)" \
    -f "$REPO_ROOT/tests/docker/Dockerfile.server" "$REPO_ROOT/tests/docker" >/dev/null
  mkdir -p "$SB/repo"
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z \
    | while IFS= read -r -d '' f; do [ -e "$f" ] || [ -L "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -xf - -C "$SB/repo"
  git -C "$SB/repo" init -q -b main && git -C "$SB/repo" add -A
  git -C "$SB/repo" -c user.name=test -c user.email=test@example.invalid commit -q -m snapshot
  cache="${DEVENV_DOCKER_CACHE:-$REPO_ROOT/.tools/docker-cache}"
  mkdir -p "$cache/mamba-pkgs" "$cache/uv"
  run docker run --rm -v "$SB/repo:/repo:ro" \
    -v "$cache/mamba-pkgs:/cache/mamba-pkgs" -v "$cache/uv:/cache/uv" \
    -e CONDA_PKGS_DIRS=/cache/mamba-pkgs -e UV_CACHE_DIR=/cache/uv \
    ${GITHUB_TOKEN:+-e GITHUB_TOKEN} "$img" bash -c '
    export PATH=$HOME/.local/bin:$PATH
    sh /repo/bootstrap.sh --source /repo --role server --ci; echo "boot-rc=$?"
    s1=$(sha256sum ~/.claude/settings.json)
    d=$(chezmoi diff --no-pager 2>/dev/null); [ -z "$d" ] && echo DIFF-EMPTY || echo "diff after bootstrap: $d"
    # rerun the install script: nothing re-registered, settings unchanged
    chezmoi execute-template < ~/.local/share/chezmoi/home/.chezmoiscripts/run_onchange_after_50-claude.sh.tmpl > /tmp/c.sh
    sh /tmp/c.sh > /tmp/c2.log 2>&1; echo "rerun-rc=$?"; cat /tmp/c2.log
    grep -qE "Added stdio MCP|Removed MCP" /tmp/c2.log && echo MCP-READDED
    [ "$(sha256sum ~/.claude/settings.json)" = "$s1" ] && echo SETTINGS-STABLE
    # bootstrap re-resolves the lock inside the container: compare with the lock it used
    echo "graphify-skill=$(cat ~/.claude/skills/graphify/.graphify_version 2>/dev/null)"
    echo "graphify-lock=$(sed -n "s/^  graphifyy: *'"'"'\{0,1\}\([^'"'"']*\)'"'"'\{0,1\}\$/\1/p" ~/.local/share/chezmoi/home/.chezmoidata/versions.yaml)"
    [ -s ~/.claude/agents/codebase-memory.md ] && echo CBM-AGENT-OK
    for h in cbm-code-discovery-gate cbm-session-reminder cbm-subagent-reminder; do
      [ -x ~/.claude/hooks/$h ] && echo "CBM-HOOK-OK $h"
    done
    claude mcp list
    ~/.local/share/chezmoi/bin/doctor --ci; echo "doctor-rc=$?"' 2>&1
  echo "$output"
  [[ "$output" == *"boot-rc=0"* ]]
  [[ "$output" == *"doctor-rc=0"* ]]
  [[ "$output" == *"rerun-rc=0"* ]]
  [[ "$output" == *DIFF-EMPTY* ]]
  [[ "$output" == *SETTINGS-STABLE* ]]
  [[ "$output" != *MCP-READDED* ]]
  used="$(printf '%s\n' "$output" | sed -n 's/^graphify-lock=//p')"
  [ -n "$used" ]
  [[ "$output" == *"graphify-skill=$used"* ]]
  [[ "$output" == *CBM-AGENT-OK* ]]
  for h in cbm-code-discovery-gate cbm-session-reminder cbm-subagent-reminder; do
    [[ "$output" == *"CBM-HOOK-OK $h"* ]]
  done
  # semble and drawio really connect (doctor claude_mcp PASS already requires it)
  printf '%s\n' "$output" | grep -q '^semble: .*Connected'
  printf '%s\n' "$output" | grep -q '^drawio: .*Connected'
  for c in claude_installed claude_plugins claude_mcp claude_skills; do
    [[ "$output" == *"PASS $c"* ]]
  done
  [[ "$output" == *"SKIP claude_login"* ]]
  ! printf '%s\n' "$output" | grep -q '^FAIL '
}
