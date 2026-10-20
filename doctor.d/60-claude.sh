# Claude Code checks (install, plugins, MCP servers, skills, login).
# Protocol: see bin/doctor. --ci: login is SKIP. Server role only: a plain
# Desktop gets no Claude Code, so every check SKIPs there.

_claude_manifest() { echo "$DOCTOR_ROOT/home/.chezmoidata/manifest.yaml"; }

_claude_present() {
  command -v claude >/dev/null 2>&1 && return 0
  echo "claude not on PATH: $DOCTOR_FIX"; return 1
}

# _claude_names SECTION [FIELD]: values of FIELD (default name) in the manifest's
# claude.SECTION list.
_claude_names() {
  awk -v sec="  $1:" -v fld="${2:-name}" '
    $0 == sec { s = 1; next }
    /^  ?[a-z_]+:/ { s = 0 }
    s && match($0, fld ": *\"?[^,}\" ]+") {
      v = substr($0, RSTART, RLENGTH); sub(fld ": *\"?", "", v); print v }' "$(_claude_manifest)"
}

# _claude_mcp_names: registered names (lock key minus "mcp-") of the manifest
# MCP servers whose clients include claude.
_claude_mcp_names() {
  awk '/^[a-z_]+:/ { s = ($1 == "mcp:") }
       s && /^  - name:/ { n = $3; sub(/^mcp-/, "", n) }
       s && /^    clients:/ && /claude/ { print n }' "$(_claude_manifest)"
}

check_claude_installed() {
  doctor_server_only || return
  _claude_present || return 1
  claude --version >/dev/null 2>&1 && return 0
  echo "claude --version failed"; return 1
}
register check_claude_installed

check_claude_plugins() {
  local list p missing=
  doctor_server_only || return
  _claude_present || return 1
  list="$(claude plugin list --json 2>/dev/null)"
  for p in $(_claude_names plugins); do
    printf '%s\n' "$list" | grep -qF "\"id\": \"$p\"" || missing="$missing $p"
  done
  [ -z "$missing" ] && return 0
  echo "plugin(s) not installed:$missing: $DOCTOR_FIX"; return 1
}
register check_claude_plugins

# Every manifest server must be registered and connect (`claude mcp list` runs
# a health check: "✔ Connected" or "✘ Failed to connect ...").
check_claude_mcp() {
  doctor_server_only || return
  local list line n missing= failed=
  _claude_present || return 1
  list="$(claude mcp list 2>/dev/null)"
  for n in $(_claude_mcp_names); do
    line="$(printf '%s\n' "$list" | grep "^$n:" | head -n1)"
    if [ -z "$line" ]; then missing="$missing $n"
    else case "$line" in *"✔"*) ;; *) failed="$failed $n(${line##* - })" ;; esac
    fi
  done
  [ -z "$missing$failed" ] && return 0
  [ -n "$missing" ] && echo "MCP server(s) not registered:$missing"
  [ -n "$failed" ] && echo "MCP server(s) not connecting:$failed"
  echo "$DOCTOR_FIX"
  return 1
}
register check_claude_mcp

check_claude_skills() {
  doctor_server_only || return
  local d missing=
  for d in $(_claude_names skills dir); do
    [ -f "$HOME/.claude/skills/$d/SKILL.md" ] || missing="$missing $d"
  done
  [ -z "$missing" ] && return 0
  echo "skill(s) missing from ~/.claude/skills:$missing: $DOCTOR_FIX"; return 1
}
register check_claude_skills

# WARN (never FAIL): no statusline release is locked yet and no local build ran
# (go missing), so settings.json has no statusLine.
check_statusline_installed() {
  doctor_server_only || return
  [ -x "$HOME/.claude/statusline-bin" ] && return 0
  echo "~/.claude/statusline-bin missing (no statusline release locked and no go to build it): install go or wait for a release, then $DOCTOR_FIX"; return 3
}
register check_statusline_installed

check_claude_login() {
  doctor_server_only || return
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "login check skipped in --ci"; return 2; fi
  _claude_present || return 1
  claude auth status >/dev/null 2>&1 && return 0
  echo "not logged in: run claude and /login"; return 1
}
register check_claude_login
