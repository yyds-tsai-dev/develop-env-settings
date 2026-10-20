# Secret checks (Bitwarden). Protocol: see bin/doctor. Skipped in --ci.

check_bw_installed() {
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  command -v bw >/dev/null 2>&1 && return 0
  echo "bw not on PATH (npm install -g @bitwarden/cli, or rerun apply)"
  return 1
}
register check_bw_installed

check_bw_unlocked() {
  local st
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  command -v bw >/dev/null 2>&1 || { echo "bw not installed"; return 1; }
  st="$(bw status 2>/dev/null)"
  case "$st" in
    *'"status":"unlocked"'*) return 0 ;;
  esac
  echo "vault not unlocked: bw login; export BW_SESSION=\$(bw unlock --raw); apply again"
  return 1
}
register check_bw_unlocked

check_paper_search_env() {
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  [ -s "$HOME/.config/paper-search-mcp/.env" ] && return 0
  echo "$HOME/.config/paper-search-mcp/.env missing (unlock Bitwarden and apply again)"
  return 1
}
register check_paper_search_env
