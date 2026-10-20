# Secret checks (Bitwarden). Protocol: see bin/doctor. Skipped in --ci. The
# paper-search .env is server role only (it feeds the Server MCP server).

check_bw_installed() {
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  command -v bw >/dev/null 2>&1 && return 0
  echo "bw not on PATH or in ~/.local/bin: $DOCTOR_FIX"
  return 1
}
register check_bw_installed

check_bw_unlocked() {
  local st
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  command -v bw >/dev/null 2>&1 || { echo "bw not installed"; return 1; }
  st="$(bw status 2>/dev/null)"
  if command -v jq >/dev/null 2>&1; then
    [ "$(printf '%s' "$st" | jq -r .status 2>/dev/null)" = unlocked ] && return 0
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$st" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("status")=="unlocked" else 1)' 2>/dev/null && return 0
  fi
  echo "vault not unlocked: bw login; export BW_SESSION=\$(bw unlock --raw); bw sync; then $DOCTOR_FIX"
  return 1
}
register check_bw_unlocked

check_paper_search_env() {
  doctor_server_only || return
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  [ -s "$HOME/.config/paper-search-mcp/.env" ] && return 0
  echo "$HOME/.config/paper-search-mcp/.env missing: unlock Bitwarden (bw login; export BW_SESSION=\$(bw unlock --raw); bw sync), then $DOCTOR_FIX"
  return 1
}
register check_paper_search_env
