# Zotero checks (every role): zotero-cli from the zotero-mcp-server uv tool
# (32-zotero), its skill for Claude Code and Codex, and the Secret config.
# Protocol: see bin/doctor.

# _zotero_hint: DOCTOR_FIX when 32-zotero failed and left a retry marker,
# DOCTOR_FORCE when it succeeded earlier and its result went missing later.
_zotero_hint() {
  if [ -e "$HOME/.local/state/develop-env/retry/32-zotero" ]; then echo "$DOCTOR_FIX"; else echo "$DOCTOR_FORCE"; fi
}

# FAIL: zotero-cli is not on PATH or does not run.
check_zotero_cli() {
  command -v zotero-cli >/dev/null 2>&1 || { echo "zotero-cli not on PATH: $(_zotero_hint)"; return 1; }
  zotero-cli --help >/dev/null 2>&1 && return 0
  echo "zotero-cli --help failed: $(_zotero_hint)"; return 1
}
register check_zotero_cli

# WARN (never FAIL): the zotero-cli skill is missing for Claude Code or Codex.
check_zotero_skills() {
  local d missing=
  for d in "$HOME/.claude/skills/zotero-cli" "$HOME/.codex/skills/zotero-cli"; do
    [ -f "$d/SKILL.md" ] && [ -f "$d/reference.md" ] || missing="$missing ${d#"$HOME"/}"
  done
  [ -z "$missing" ] && return 0
  echo "zotero-cli skill missing:$missing: $(_zotero_hint)"; return 3
}
register check_zotero_skills

# WARN (never FAIL): the Secret ~/.config/zotero-mcp/config.json (from the
# Bitwarden item zotero) is missing. Skipped in --ci.
check_zotero_config() {
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  [ -s "$HOME/.config/zotero-mcp/config.json" ] && return 0
  echo "$HOME/.config/zotero-mcp/config.json missing: create the Bitwarden item zotero (fields api_key, library_id), unlock Bitwarden (bw login; export BW_SESSION=\$(bw unlock --raw); bw sync), then $DOCTOR_FIX"
  return 3
}
register check_zotero_config
