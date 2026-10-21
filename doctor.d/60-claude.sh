# Claude Code checks (install, plugins, MCP servers, skills, login).
# Protocol: see bin/doctor. --ci: login is SKIP. Every role: on a plain Desktop
# only the MCP servers whose command exists and the installer-made skills whose
# installer exists are expected (50-claude skips the others with a warning).

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

# _claude_desktop: true on a plain Desktop (no server role).
_claude_desktop() {
  case "$DOCTOR_ROLE" in server|desktop+server) return 1 ;; esac
  return 0
}

# _claude_mcp_names: registered names (lock key minus "mcp-") of the manifest
# MCP servers whose clients include claude; on a plain Desktop only those whose
# command is on PATH.
_claude_mcp_names() {
  local n c
  awk '/^[a-z_]+:/ { s = ($1 == "mcp:") }
       s && /^  - name:/ { n = $3; sub(/^mcp-/, "", n); c = "" }
       s && /^    command:/ { c = $2 }
       s && /^    clients:/ && /claude/ { print n, c }' "$(_claude_manifest)" |
  while read -r n c; do
    if _claude_desktop && ! command -v "$c" >/dev/null 2>&1; then continue; fi
    echo "$n"
  done
}

# _claude_skill_dirs: the manifest skill dirs; on a plain Desktop an
# installer-made skill only when its installer command is on PATH.
_claude_skill_dirs() {
  local d i
  awk '/^  skills:/ { s = 1; next } /^  ?[a-z_]+:/ { s = 0 }
       s && match($0, /dir: *[^,} ]+/) {
         d = substr($0, RSTART, RLENGTH); sub(/dir: */, "", d); i = "-"
         if (match($0, /installer: *[^,} ]+/)) { i = substr($0, RSTART, RLENGTH); sub(/installer: */, "", i) }
         print d, i }' "$(_claude_manifest)" |
  while read -r d i; do
    if [ "$i" != - ] && _claude_desktop && ! command -v "$i" >/dev/null 2>&1; then continue; fi
    echo "$d"
  done
}

check_claude_installed() {
  _claude_present || return 1
  claude --version >/dev/null 2>&1 && return 0
  echo "claude --version failed"; return 1
}
register check_claude_installed

check_claude_plugins() {
  local list p missing=
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
  # A server that is registered but not connecting is not a failed install
  # step (50-claude left no marker); its binary usually went missing.
  [ -n "$missing" ] && echo "MCP server(s) not registered:$missing: $DOCTOR_FIX"
  [ -n "$failed" ] && echo "MCP server(s) not connecting:$failed: $DOCTOR_FORCE"
  return 1
}
register check_claude_mcp

check_claude_skills() {
  local d missing=
  for d in $(_claude_skill_dirs); do
    [ -f "$HOME/.claude/skills/$d/SKILL.md" ] || missing="$missing $d"
  done
  [ -z "$missing" ] && return 0
  echo "skill(s) missing from ~/.claude/skills:$missing: $DOCTOR_FIX"; return 1
}
register check_claude_skills

# WARN (never FAIL): no statusline release is locked yet and no local build ran
# (go missing), so settings.json has no statusLine.
check_statusline_installed() {
  [ -x "$HOME/.claude/statusline-bin" ] && return 0
  echo "~/.claude/statusline-bin missing (the statusline release download failed and no go to build it): $DOCTOR_FIX"; return 3
}
register check_statusline_installed

check_claude_login() {
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "login check skipped in --ci"; return 2; fi
  _claude_present || return 1
  claude auth status >/dev/null 2>&1 && return 0
  echo "not logged in: run claude and /login"; return 1
}
register check_claude_login
