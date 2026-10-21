#!/usr/bin/env bats
# Desktop role: WezTerm config, ~/.ssh/config (Bitwarden note ssh-hosts), the VS
# Code settings snippet, role ignores, install scripts, Doctor and the VS Code
# server extension fallback. A stub `bw` answers status/list; all hosts are
# fake (*.example.invalid). Sandboxes live under the temp dir only.
#
# chezmoi takes .chezmoi.os from the host and the desktop role is refused on
# Linux, so on Linux init_desktop writes a server config and rewrites its data
# to the desktop role: role-gated files then render as on a Desktop (OS-gated
# scripts are rendered with the OS test substituted, see render_for).

load helpers

setup() {
  new_sandbox
  STUB="$SB/stub"; mkdir -p "$STUB"
  HOST_OS="$(uname -s)"
}
teardown() { rm -rf "$SB"; }

is_windows() { case "$HOST_OS" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }

# init_desktop [ROLE]: ROLE is desktop (default) or desktop+server.
init_desktop() {
  local role="${1:-desktop}" srv=false
  [ "$role" = "desktop+server" ] && srv=true
  if [ "$HOST_OS" = Darwin ] || { is_windows && [ "$role" = desktop ]; }; then
    init_role "$role" >&2
    return
  fi
  is_windows && skip "$role role needs darwin"
  init_role server >&2 || return 1
  sed -e "s/^\( *role = \).*/\1\"$role\"/" -e "s/^\( *isServer = \).*/\1$srv/" \
      -e 's/^\( *isDesktop = \).*/\1true/' "$SB_CONFIG" > "$SB/cfg.new"
  cat "$SB/cfg.new" > "$SB_CONFIG"
}

# stub_bw STATUS [NOTES_JSON_STRING]: fake `bw` reporting STATUS, with an
# ssh-hosts item whose notes default to two hosts (NOTES is already JSON-escaped).
stub_bw() {
  local notes="${2:-}"
  [ -n "$notes" ] || notes='[{\"alias\":\"lab1\",\"hostname\":\"lab1.example.invalid\",\"user\":\"alice\",\"port\":22},{\"alias\":\"lab2\",\"hostname\":\"lab2.example.invalid\",\"user\":\"bob\",\"port\":2222}]'
  printf '[{"name":"ssh-hosts","notes":"%s"}]\n' "$notes" > "$SB/ssh-hosts.json"
  cat > "$STUB/bw" <<STUBEOF
#!/bin/sh
case "\$1 \$2" in
  "status "*) echo '{"status":"$1"}' ;;
  "list folders") echo '[{"id":"fld1","name":"develop-env-settings"}]' ;;
  "list items")
    case "\$*" in
      *ssh-hosts*) cat "$SB/ssh-hosts.json" ;;
      *) echo '[]' ;;
    esac ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "$STUB/bw"
}

# chezmoi on Windows runs bw through PowerShell, which cannot run a sh stub.
need_bw_stub() { is_windows && skip "bw stub is a sh script; chezmoi on Windows calls bw through PowerShell"; return 0; }

# apply_with PATHPREFIX: apply (no scripts) with stderr captured in $output.
apply_with() {
  HOME="$SB_HOME" USERPROFILE="$SB_HOME" XDG_CONFIG_HOME="$SB_HOME/.config" \
    PATH="$1:$PATH" run chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
}

checksum() { cksum < "$1"; }

# render_for OS SCRIPT: render a .chezmoiscripts template as if .chezmoi.os were
# OS: every .chezmoi.os becomes the literal "OS", so eq and ne tests against any
# OS (e.g. 25-bw's ne .chezmoi.os "windows") hold as on that OS whatever the host.
render_for() {
  sed "s/\.chezmoi\.os/\"$1\"/g" "$REPO_ROOT/home/.chezmoiscripts/$2" > "$SB/$2"
  chezmoi_iso execute-template < "$SB/$2" > "$SB/$2.out"
  echo "$SB/$2.out"
}

# ps_parse FILE: PowerShell syntax check (pwsh must be on PATH).
ps_parse() {
  cat > "$SB/parse.ps1" <<'EOF'
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$null, [ref]$e)
if ($e) { $e | ForEach-Object { $_.ToString() }; exit 1 }
exit 0
EOF
  pwsh -NoProfile -File "$SB/parse.ps1" "$1"
}

@test "wezterm config has one ssh domain per host with tmux new -As wez" {
  need_bw_stub
  init_desktop
  stub_bw unlocked
  apply_with "$STUB"
  echo "$output"
  [ "$status" -eq 0 ]
  f="$SB_DEST/.wezterm.lua"
  [ -f "$f" ]
  grep -qF "wezterm.font 'JetBrainsMono Nerd Font'" "$f"
  grep -q "^config.color_scheme = '" "$f"
  [ "$(grep -c 'multiplexing = "None"' "$f")" -eq 2 ]
  [ "$(grep -cF 'default_prog = { "bash", "-lc", "tmux new -As wez" }' "$f")" -eq 2 ]
  grep -qF 'name = "lab1"' "$f"
  grep -qF 'remote_address = "lab1.example.invalid:22"' "$f"
  grep -qF 'remote_address = "lab2.example.invalid:2222"' "$f"
  grep -qF 'username = "bob"' "$f"
  if command -v luac >/dev/null 2>&1; then luac -p "$f"; fi
  # ~/.ssh/config comes from the same note
  c="$SB_DEST/.ssh/config"
  [ -f "$c" ]
  [ "$(grep -c '^Host ' "$c")" -eq 2 ]
  grep -qx '    HostName lab2.example.invalid' "$c"
  grep -qx '    User bob' "$c"
  grep -qx '    Port 2222' "$c"
}

@test "locked vault: wezterm config renders with empty ssh_domains and no ~/.ssh/config" {
  init_desktop
  stub_bw locked
  apply_with "$STUB"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx 'config.ssh_domains = {}' "$SB_DEST/.wezterm.lua"
  ! grep -q 'remote_address' "$SB_DEST/.wezterm.lua"
  [ ! -e "$SB_DEST/.ssh/config" ]
  [ "$(grep -c 'Bitwarden locked or missing: skipping .ssh/config' <<<"$output")" -eq 1 ]
}

@test "locked re-apply leaves an existing ~/.ssh/config byte-identical" {
  need_bw_stub
  init_desktop
  stub_bw unlocked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  before="$(checksum "$SB_DEST/.ssh/config")"
  wez="$(checksum "$SB_DEST/.wezterm.lua")"
  stub_bw locked
  apply_with "$STUB"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(checksum "$SB_DEST/.ssh/config")" = "$before" ]
  # an existing .wezterm.lua keeps its domains too, with one warning
  [ "$(checksum "$SB_DEST/.wezterm.lua")" = "$wez" ]
  grep -qF 'remote_address = "lab1.example.invalid:22"' "$SB_DEST/.wezterm.lua"
  [ "$(grep -c 'Bitwarden locked or missing: skipping .wezterm.lua' <<<"$output")" -eq 1 ]
}

@test "a host without user or port gets port 22 and no user line" {
  need_bw_stub
  init_desktop
  stub_bw unlocked '[{\"alias\":\"bare\",\"hostname\":\"bare.example.invalid\"},{\"hostname\":\"noalias.example.invalid\"}]'
  apply_with "$STUB"
  echo "$output"
  [ "$status" -eq 0 ]
  f="$SB_DEST/.wezterm.lua"
  grep -qF 'remote_address = "bare.example.invalid:22"' "$f"
  ! grep -q 'username' "$f"
  ! grep -q 'noalias' "$f"
  c="$SB_DEST/.ssh/config"
  grep -qx 'Host bare' "$c"
  grep -qx '    Port 22' "$c"
  ! grep -q '^    User' "$c"
  ! grep -q 'noalias' "$c"
}

@test "a note that is not a JSON list warns and skips, apply exits 0" {
  need_bw_stub
  init_desktop
  stub_bw unlocked 'lab1 lab1.example.invalid'
  apply_with "$STUB"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/.ssh/config" ]
  grep -qx 'config.ssh_domains = {}' "$SB_DEST/.wezterm.lua"
  [[ "$output" == *"not a JSON list: skipping .ssh/config"* ]]
}

@test "~/.ssh/config is mode 600" {
  need_bw_stub
  is_windows && skip "no Unix modes on Windows"
  init_desktop
  stub_bw unlocked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$SB_DEST/.ssh/config" 2>/dev/null || stat -f %Lp "$SB_DEST/.ssh/config")" = 600 ]
}

@test "settings-sync.jsonc lists every server extension" {
  d="$REPO_ROOT/desktop/vscode"
  [ "$(grep -cv '^[[:space:]]*$' "$d/server-extensions.txt")" -eq 15 ]
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    grep -qF "\"$id\"" "$d/settings-sync.jsonc" || { echo "missing $id" >&2; false; }
  done < "$d/server-extensions.txt"
  # and nothing else: the defaultExtensions list has exactly as many entries
  n="$(awk '/"remote.SSH.defaultExtensions"/ { s = 1; next } s && /\]/ { s = 0 } s && /"/ { c++ } END { print c + 0 }' "$d/settings-sync.jsonc")"
  [ "$n" -eq 15 ]
  grep -qF '"terminal.integrated.fontFamily": "JetBrainsMono Nerd Font"' "$d/settings-sync.jsonc"
  py="$(command -v python3 || command -v python || true)"
  if [ -n "$py" ]; then
    grep -v '^[[:space:]]*//' "$d/settings-sync.jsonc" | "$py" -c 'import json,sys; json.load(sys.stdin)'
  fi
}

@test "desktop role on darwin ignores server-only files" {
  init_desktop
  stub_bw locked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  for p in .tmux.conf .bashrc .tcshrc .cshrc .condarc .config/fish .config/git .codex .claude .config/paper-search-mcp .ssh/authorized_keys; do
    [ ! -e "$SB_DEST/$p" ] || { echo "server-only $p rendered on a desktop" >&2; false; }
  done
  [ -f "$SB_DEST/.wezterm.lua" ]
}

@test "server role does not manage wezterm or ~/.ssh/config" {
  [ "$HOST_OS" = Linux ] || skip "server role needs linux"
  command -v uv >/dev/null 2>&1 || skip "uv needed for the server render"
  init_role server >&2
  stub_bw unlocked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/.wezterm.lua" ]
  [ ! -e "$SB_DEST/.ssh/config" ]
}

@test "macOS desktop script installs wezterm, git, gh, vscode and the font in user scope" {
  init_desktop
  f="$(render_for darwin run_onchange_after_70-desktop.sh.tmpl)"
  head -n1 "$f" | grep -q '^#!/bin/sh'
  sh -n "$f"
  grep -q 'install --cask --appdir="$HOME/Applications"' "$f"
  for p in wezterm visual-studio-code git gh; do grep -qw "$p" "$f"; done
  grep -q 'Library/Fonts' "$f"
  ! grep -q 'sudo ' "$f"
}

@test "macOS desktop script prints the Homebrew install command and exits 0 without brew" {
  [ "$HOST_OS" = Darwin ] && skip "the script would find this host's real Homebrew"
  # The run below puts only symlinked binaries on PATH; under MSYS `ln -s` copies
  # them and a copied sh cannot find its DLLs, so the script cannot even start.
  [ "$HOST_OS" = Linux ] || skip "needs real symlinks for a stub-only PATH (MSYS ln -s copies)"
  init_desktop
  f="$(render_for darwin run_onchange_after_70-desktop.sh.tmpl)"
  printf '#!/bin/sh\nexit 1\n' > "$STUB/curl"; chmod +x "$STUB/curl"
  for t in sh uname mkdir rm mktemp cat; do
    p="$(command -v "$t")" && ln -s "$p" "$STUB/$t"
  done
  HOME="$SB_HOME" PATH="$STUB" run "$STUB/sh" "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Homebrew"* ]]
  [[ "$output" == *"/bin/bash -c"*"Homebrew/install"* ]]
}

@test "mac cli tools script brew-installs the darwin cli_tools only for desktop+server" {
  init_desktop desktop
  f="$(render_for darwin run_onchange_after_12-mac-cli-tools.sh.tmpl)"
  [ -z "$(tr -d '[:space:]' < "$f")" ]
  rm -rf "$SB/cache" "$SB_CONFIG"; mkdir -p "$SB_CACHE"
  init_desktop "desktop+server"
  f="$(render_for darwin run_onchange_after_12-mac-cli-tools.sh.tmpl)"
  sh -n "$f"
  for p in fish tmux fzf fd bat ripgrep jq gh git-lfs; do grep -q "^brew_formula $p\$" "$f"; done
  ! grep -q 'fd-find' "$f"
}

@test "mac cli tools run before fish plugins and node; fish plugins see Homebrew on PATH" {
  ls "$REPO_ROOT/home/.chezmoiscripts" | grep -E '^run_onchange_after_[0-9]+' | sort > "$SB/order"
  first="$(grep -nE '12-mac-cli-tools|20-fish-plugins|20-node|30-uv-tools' "$SB/order" | head -n1)"
  [[ "$first" == *"12-mac-cli-tools"* ]]
  init_desktop "desktop+server"
  f="$(render_for darwin run_onchange_after_20-fish-plugins.sh.tmpl)"
  sh -n "$f"
  grep -q '/opt/homebrew/bin' "$f"
}

@test "node script renders on a plain macOS desktop so 25-bw has npm" {
  init_desktop desktop
  f="$(render_for darwin run_onchange_after_20-node.sh.tmpl)"
  sh -n "$f"
  grep -q 'fnm-macos.zip' "$f"
  f="$(render_for darwin run_onchange_after_25-bw.sh.tmpl)"
  grep -q 'npm install -g' "$f"
}

@test "node and uv tools scripts also render for macOS desktop+server" {
  init_desktop "desktop+server"
  f="$(render_for darwin run_onchange_after_20-node.sh.tmpl)"
  sh -n "$f"
  grep -q 'fnm-macos.zip' "$f"
  f="$(render_for darwin run_onchange_after_30-uv-tools.sh.tmpl)"
  sh -n "$f"
  grep -q 'uv tool install' "$f"
}

@test "windows desktop script uses winget user scope and prints admin commands" {
  init_desktop
  f="$(render_for windows run_onchange_after_70-desktop.ps1.tmpl)"
  [ -s "$f" ]
  grep -q -- '--scope user' "$f"
  for id in wez.wezterm Git.Git GitHub.cli Microsoft.VisualStudioCode; do grep -qF "$id" "$f"; done
  grep -q 'LOCALAPPDATA' "$f"
  ! grep -qi 'runas\|sudo ' "$f"
  if command -v pwsh >/dev/null 2>&1; then
    run ps_parse "$f"
    echo "$output"
    [ "$status" -eq 0 ]
  fi
}

@test "bootstrap.ps1 and the PowerShell doctor files parse" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  for f in bootstrap.ps1 bin/doctor.ps1 doctor.d/*.ps1; do
    run ps_parse "$REPO_ROOT/$f"
    echo "$f: $output"
    [ "$status" -eq 0 ]
  done
}

@test "doctor.ps1 prints WARN for an advisory check and still exits 0" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  mkdir -p "$SB/r/bin" "$SB/r/doctor.d"
  cp "$REPO_ROOT/bin/doctor.ps1" "$SB/r/bin/"
  cat > "$SB/r/doctor.d/10-x.ps1" <<'EOF'
function check_a { return $null }
Register 'check_a'
function check_b { return @{ Status = 'WARN'; Reason = 'advisory' } }
Register 'check_b'
EOF
  run pwsh -NoProfile -File "$SB/r/bin/doctor.ps1" -Ci
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS a"* ]]
  [[ "$output" == *"WARN b: advisory"* ]]
}

@test "doctor: server-only checks SKIP on a desktop role, run on a server role" {
  printf '[user]\n\temail = t@example.invalid\n' > "$SB_HOME/.gitconfig"   # git_user_email is role-independent
  for c in 10 20 65; do
    DEVENV_ROLE=desktop HOME="$SB_HOME" DOCTOR_ONLY="$c-*" run "$REPO_ROOT/bin/doctor" --ci
    echo "$output"
    [ "$status" -eq 0 ]
    ! grep -q '^FAIL' <<<"$output"
  done
  DEVENV_ROLE=desktop HOME="$SB_HOME" DOCTOR_ONLY='20-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"SKIP fish_present: server role only (role: desktop)"* ]]
  DEVENV_ROLE=desktop HOME="$SB_HOME" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"SKIP codex_installed: server role only"* ]]
  DEVENV_ROLE=desktop HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"SKIP claude_mcp: server role only"* ]]
  [[ "$output" == *"SKIP claude_skills: server role only"* ]]
  DEVENV_ROLE=server HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"codex_installed"* ]]
  [[ "$output" != *"server role only"* ]]
}

@test "doctor.ps1 takes the role from DEVENV_ROLE" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  mkdir -p "$SB/r/bin" "$SB/r/doctor.d"
  cp "$REPO_ROOT/bin/doctor.ps1" "$SB/r/bin/"
  cat > "$SB/r/doctor.d/10-x.ps1" <<'EOF'
function check_srv { return (Test-DoctorServerOnly) }
Register 'check_srv'
EOF
  DEVENV_ROLE=desktop run pwsh -NoProfile -File "$SB/r/bin/doctor.ps1" -Ci
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP srv: server role only (role: desktop)"* ]]
  DEVENV_ROLE=server run pwsh -NoProfile -File "$SB/r/bin/doctor.ps1" -Ci
  [[ "$output" == *"PASS srv"* ]]
}

@test "windows chezmoi config runs ps1 scripts with ExecutionPolicy Bypass" {
  grep -q 'interpreters.ps1' "$REPO_ROOT/home/.chezmoi.toml.tmpl"
  grep -qF '"-ExecutionPolicy", "Bypass"' "$REPO_ROOT/home/.chezmoi.toml.tmpl"
  grep -q 'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force' "$REPO_ROOT/bootstrap.ps1"
  if ! is_windows; then init_desktop; ! grep -q interpreters "$SB_CONFIG"; fi
}

@test "doctor desktop checks register only on macOS" {
  HOME="$SB_HOME" DOCTOR_ONLY='70-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  if [ "$HOST_OS" = Darwin ]; then
    [[ "$output" == *"wezterm_config"* ]]
    [[ "$output" == *"SKIP ssh_config"* ]]
  else
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  fi
}

@test "doctor desktop checks on macOS: font and wezterm config fail when missing" {
  [ "$HOST_OS" = Darwin ] || skip "macOS desktop checks"
  HOME="$SB_HOME" DOCTOR_ONLY='70-*' run "$REPO_ROOT/bin/doctor" --ci
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL nerd_font"* ]]
  [[ "$output" == *"FAIL wezterm_config"* ]]
  mkdir -p "$SB_HOME/Library/Fonts"; : > "$SB_HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"
  : > "$SB_HOME/.wezterm.lua"
  HOME="$SB_HOME" DOCTOR_ONLY='70-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"PASS nerd_font"* ]]
  [[ "$output" == *"PASS wezterm_config"* ]]
}

# vscode_stub: a remote-cli `code` under ~/.vscode-server that knows one extension.
vscode_stub() {
  CODE_DIR="$SB_HOME/.vscode-server/cli/servers/Stable-x/server/bin/remote-cli"
  mkdir -p "$CODE_DIR"
  cat > "$CODE_DIR/code" <<EOF
#!/bin/sh
case "\$1" in
  --list-extensions) echo "anthropic.claude-code"; echo "MS-Python.Python" ;;
  --install-extension) echo "\$2" >> "$SB/installed" ;;
esac
exit 0
EOF
  chmod +x "$CODE_DIR/code"
}

@test "vscode-server-extensions installs only the missing server extensions" {
  vscode_stub
  HOME="$SB_HOME" PATH="$CODE_DIR:$PATH" run "$REPO_ROOT/bin/vscode-server-extensions"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SB/installed")" -eq 13 ]
  ! grep -q 'anthropic.claude-code' "$SB/installed"
  ! grep -qi 'ms-python.python$' "$SB/installed"
  grep -qx 'tamasfe.even-better-toml' "$SB/installed"
}

@test "vscode-server-extensions skips outside a VS Code server terminal and exits 0" {
  printf '#!/bin/sh\necho "$*" >> "%s/called"\n' "$SB" > "$STUB/code"; chmod +x "$STUB/code"
  HOME="$SB_HOME" PATH="$STUB:$PATH" run "$REPO_ROOT/bin/vscode-server-extensions"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]]
  [ ! -e "$SB/called" ]
}

@test "machine-local runs the vscode server extensions fallback" {
  grep -q 'vscode-server-extensions' "$REPO_ROOT/bin/machine-local"
  bash -n "$REPO_ROOT/bin/vscode-server-extensions"
  [ -x "$REPO_ROOT/bin/vscode-server-extensions" ]
}

@test "claude settings point the status line at statusline-bin.exe on windows only" {
  init_desktop
  # with a locked release, so statusLine renders
  t='{{ template "claude-settings.json" (merge (dict "chezmoi" (merge (dict "os" "OS") .chezmoi) "versions" (dict "statusline" "1.0.0")) .) }}'
  run chezmoi_iso execute-template "${t/OS/windows}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"command": "\"$HOME/.claude/statusline-bin.exe\""'* ]]
  run chezmoi_iso execute-template "${t/OS/darwin}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"command": "\"$HOME/.claude/statusline-bin\""'* ]]
}

@test "mac scripts carry a Homebrew marker so installing Homebrew reruns them" {
  init_desktop "desktop+server"
  if [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; then want=present; else want=absent; fi
  for s in run_onchange_after_12-mac-cli-tools.sh.tmpl run_onchange_after_70-desktop.sh.tmpl run_onchange_after_20-fish-plugins.sh.tmpl; do
    f="$(render_for darwin "$s")"
    sh -n "$f"
    grep -qx "# brew: $want" "$f" || { echo "$s: no brew marker"; false; }
  done
  # 70-desktop: a failed font download leaves a retry marker whose nonce the next render shows
  f="$(render_for darwin run_onchange_after_70-desktop.sh.tmpl)"
  grep -qx '# retry: ' "$f"
  mkdir -p "$SB_HOME/.local/state/develop-env/retry"; echo 1700000000.42 > "$SB_HOME/.local/state/develop-env/retry/70-desktop"
  f="$(render_for darwin run_onchange_after_70-desktop.sh.tmpl)"
  grep -qx '# retry: 1700000000.42' "$f"
}

@test "bw script links npm's bw into ~/.local/bin, never over a regular file" {
  [ "$HOST_OS" = Linux ] || skip "stub npm is a sh script; linux host only"
  init_desktop
  f="$(render_for darwin run_onchange_after_25-bw.sh.tmpl)"
  sh -n "$f"
  v="$(sed -n "s/^  bw: *'\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$REPO_ROOT/home/.chezmoidata/versions.yaml")"
  P="$SB/npm-global"
  cat > "$STUB/npm" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "prefix -g") echo "$P" ;;
  "install -g") mkdir -p "$P/bin"; printf '#!/bin/sh\necho $v\n' > "$P/bin/bw"; chmod +x "$P/bin/bw" ;;
esac
EOF
  chmod +x "$STUB/npm"
  HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$SB_HOME/.local/bin/bw" ]
  [ "$("$SB_HOME/.local/bin/bw" --version)" = "$v" ]
  [ ! -e "$SB_HOME/.local/state/develop-env/retry/25-bw" ]
  # a regular file is kept, with a warning
  rm "$SB_HOME/.local/bin/bw"; printf 'mine\n' > "$SB_HOME/.local/bin/bw"
  HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  [ "$status" -eq 0 ]
  [ "$(cat "$SB_HOME/.local/bin/bw")" = mine ]
  [[ "$output" == *"regular file"* ]]
  # already at the locked version: still linked
  rm "$SB_HOME/.local/bin/bw"
  HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  [ -L "$SB_HOME/.local/bin/bw" ]
  # no npm: warns, exits 0, leaves a retry marker; each failure writes a new nonce
  rm "$STUB/npm"
  HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  [ "$status" -eq 0 ]
  n1="$(cat "$SB_HOME/.local/state/develop-env/retry/25-bw")"; [ -n "$n1" ]
  HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  n2="$(cat "$SB_HOME/.local/state/develop-env/retry/25-bw")"; [ -n "$n2" ] && [ "$n2" != "$n1" ]
}

@test "doctor puts ~/.local/bin first and finds bw there; paper-search check is server only" {
  is_windows && skip "stub bw is a sh script"
  mkdir -p "$SB_HOME/.local/bin"
  printf '#!/bin/sh\necho %s\n' "'{\"status\":\"unlocked\"}'" > "$SB_HOME/.local/bin/bw"; chmod +x "$SB_HOME/.local/bin/bw"
  DEVENV_ROLE=desktop HOME="$SB_HOME" PATH="/usr/bin:/bin" DOCTOR_ONLY='50-*' run "$REPO_ROOT/bin/doctor"
  echo "$output"
  [[ "$output" == *"PASS bw_installed"* ]]
  [[ "$output" == *"SKIP paper_search_env: server role only"* ]]
}

@test "doctor: plain desktop SKIPs every Claude check; server role WARNs on a missing status line" {
  DEVENV_ROLE=desktop HOME="$SB_HOME" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor"
  echo "$output"
  [ "$status" -eq 0 ]
  for c in claude_installed claude_plugins claude_mcp claude_skills statusline_installed claude_login; do
    [[ "$output" == *"SKIP $c: server role only"* ]]
  done
  DEVENV_ROLE=server HOME="$SB_HOME" DOCTOR_ONLY='60-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [[ "$output" == *"WARN statusline_installed:"*"release download failed"*"bin/update"* ]]
  [[ "$output" != *"no statusline release locked"* ]]
}

@test "macOS ~/.zshrc renders through the real ignore and sources cleanly" {
  [ "$HOST_OS" = Darwin ] || skip "~/.zshrc is managed on macOS only"
  init_desktop
  stub_bw locked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  f="$SB_DEST/.zshrc"
  [ -f "$f" ]
  grep -q '^# >>> develop-env >>>' "$f"
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  zsh -n "$f"
  # non-interactive: no error and no exec fish
  HOME="$SB_HOME" run zsh -c 'source "$1"; echo sourced-ok' _ "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *sourced-ok* ]]
}
