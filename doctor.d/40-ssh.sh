# SSH checks (Server). Protocol: see bin/doctor.

check_ssh_key() {
  [ -f "$HOME/.ssh/id_ed25519.pub" ] && return 0
  echo "$HOME/.ssh/id_ed25519.pub is missing"
  return 1
}
register check_ssh_key

check_github_ssh_auth() {
  local out
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "login check skipped in --ci"; return 2; fi
  command -v ssh >/dev/null 2>&1 || { echo "ssh not found"; return 1; }
  out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com 2>&1 </dev/null)"
  case "$out" in
    *"successfully authenticated"*) return 0 ;;
  esac
  echo "ssh -T git@github.com did not authenticate"
  return 1
}
register check_github_ssh_auth
