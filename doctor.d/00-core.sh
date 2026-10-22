# Core doctor checks. Protocol: see bin/doctor.

check_chezmoi_present() {
  if command -v chezmoi >/dev/null 2>&1 \
     || [ -x "$DOCTOR_ROOT/.tools/bin/chezmoi" ] \
     || [ -x "$DOCTOR_ROOT/.tools/bin/chezmoi.exe" ]; then
    return 0
  fi
  echo "chezmoi not on PATH and not in .tools/bin"
  return 1
}
register check_chezmoi_present

# WARN (never FAIL): an install script failed (download, or a prerequisite not
# there yet) and left a retry marker holding a nonce; every apply reruns it
# until it succeeds.
check_install_retries() {
  local d="$HOME/.local/state/develop-env/retry" f pending=
  for f in "$d"/*; do [ -e "$f" ] && pending="$pending ${f##*/}"; done
  [ -z "$pending" ] && return 0
  echo "install scripts waiting for a retry:$pending: $DOCTOR_FIX"; return 3
}
register check_install_retries

# FAIL: a group- or other-writable ~/.local or ~/.local/bin (a umask 002 home)
# makes the codebase-memory-mcp installer refuse to install, so its install
# scripts retry forever. bootstrap and the install scripts tighten them.
check_local_bin_perms() {
  local d bad=
  for d in "$HOME/.local" "$HOME/.local/bin"; do
    [ -d "$d" ] || continue
    case "$(ls -ldL "$d" 2>/dev/null)" in
      ?????w*|????????w*) bad="$bad $d" ;;
    esac
  done
  [ -z "$bad" ] && return 0
  echo "group/other-writable:$bad (the codebase-memory-mcp installer refuses it): run chmod go-w$bad"
  return 1
}
register check_local_bin_perms
