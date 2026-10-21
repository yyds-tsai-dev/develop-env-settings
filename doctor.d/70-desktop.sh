# macOS Desktop checks (WezTerm, VS Code, git, gh, Nerd Font, ~/.ssh/config).
# Protocol: see bin/doctor. Registers nothing off macOS (Windows: 70-desktop.ps1).
# Homebrew-installed apps WARN when missing: Homebrew itself needs admin rights,
# so 70-desktop may only have printed its install command. --ci: the
# Secret-backed ~/.ssh/config check is SKIP.
[ "$(uname -s)" = Darwin ] || return 0

_desktop_app() {  # _desktop_app CMD APP: CMD on PATH or APP.app in ~/Applications or /Applications
  command -v "$1" >/dev/null 2>&1 || [ -d "$HOME/Applications/$2.app" ] || [ -d "/Applications/$2.app" ]
}

check_git() {
  git --version >/dev/null 2>&1 && return 0
  echo "git missing (xcode-select --install, or brew install git)"; return 1
}
register check_git

check_gh() {
  command -v gh >/dev/null 2>&1 && return 0
  echo "gh missing (brew install gh)"; return 3
}
register check_gh

check_wezterm() {
  _desktop_app wezterm WezTerm && return 0
  echo "WezTerm missing (brew install --cask --appdir=~/Applications wezterm)"; return 3
}
register check_wezterm

check_vscode() {
  _desktop_app code "Visual Studio Code" && return 0
  echo "VS Code missing (brew install --cask --appdir=~/Applications visual-studio-code)"; return 3
}
register check_vscode

check_nerd_font() {
  local f
  for f in "$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf" "/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"; do
    [ -f "$f" ] && return 0
  done
  echo "JetBrainsMono Nerd Font not in ~/Library/Fonts (the font download failed): $DOCTOR_FIX"; return 1
}
register check_nerd_font

check_wezterm_config() {
  [ -f "$HOME/.wezterm.lua" ] && return 0
  echo "~/.wezterm.lua missing: $DOCTOR_FIX"; return 1
}
register check_wezterm_config

check_ssh_config() {
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "secret check skipped in --ci"; return 2; fi
  [ -s "$HOME/.ssh/config" ] && return 0
  echo "~/.ssh/config missing: unlock Bitwarden (bw login; export BW_SESSION=\$(bw unlock --raw); bw sync), then $DOCTOR_FIX"; return 1
}
register check_ssh_config
