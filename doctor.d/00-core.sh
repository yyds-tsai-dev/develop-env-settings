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
