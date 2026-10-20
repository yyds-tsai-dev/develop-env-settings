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
# there yet) and left a retry marker; the next apply reruns it.
check_install_retries() {
  local d="$HOME/.local/state/develop-env/retry" f pending=
  for f in "$d"/*; do [ -e "$f" ] && pending="$pending ${f##*/}"; done
  [ -z "$pending" ] && return 0
  echo "install scripts waiting for a retry:$pending: $DOCTOR_FIX"; return 3
}
register check_install_retries
