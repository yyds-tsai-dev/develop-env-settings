# Shell, tmux and git checks (Linux Server). Protocol: see bin/doctor.

_fish_bin() {
  if command -v fish >/dev/null 2>&1; then echo fish
  elif [ -x "$HOME/.local/bin/fish" ]; then echo "$HOME/.local/bin/fish"
  else return 1; fi
}

check_fish_present() {
  _fish_bin >/dev/null && return 0
  echo "fish not found on PATH or in ~/.local/bin"
  return 1
}
register check_fish_present

check_fisher_tide() {
  local fish; fish="$(_fish_bin)" || { echo "fish not found"; return 1; }
  if "$fish" -c 'fisher list' 2>/dev/null | grep -q '^ilancosman/tide'; then return 0; fi
  echo "fisher list does not contain ilancosman/tide"
  return 1
}
register check_fisher_tide

check_tmux_version() {
  local v
  command -v tmux >/dev/null 2>&1 || { echo "tmux not found"; return 1; }
  v="$(tmux -V | sed -E 's/^tmux[^0-9]*([0-9]+\.[0-9]+).*/\1/')"
  case "$v" in
    [0-9]*.[0-9]*) ;;
    *) echo "cannot parse tmux version: $(tmux -V)"; return 1 ;;
  esac
  if [ "${v%%.*}" -ge 3 ]; then return 0; fi
  echo "tmux $v is older than 3.0"
  return 1
}
register check_tmux_version

check_git_user_email() {
  if [ -n "$(git config user.email 2>/dev/null)" ]; then return 0; fi
  echo "git config user.email is empty"
  return 1
}
register check_git_user_email
