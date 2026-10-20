load helpers

setup() {
  is_linux() { [ "$(uname -s)" = "Linux" ]; }
  is_linux || skip "server render needs linux"
  FISH="$(command -v fish || true)"
  [ -n "$FISH" ] || { [ -x "$HOME/.local/bin/fish" ] && FISH="$HOME/.local/bin/fish"; } || true
}

# render_server: render the server role once per test; sets DEST.
render_server() {
  run render_home server
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  DEST="${lines[${#lines[@]}-1]}"
}

@test "rendered bashrc puts ~/.local/bin first exactly once" {
  render_server
  [ -f "$DEST/.bashrc" ]
  h="$(mktemp -d "${TMPDIR:-/tmp}/devenv-h.XXXXXX")"
  out="$(env -i HOME="$h" PATH="/usr/bin:/bin:$h/.local/bin:/opt/x" \
    bash --norc -c '. "$1"; . "$1"; echo "$PATH"' _ "$DEST/.bashrc")"
  [ "${out%%:*}" = "$h/.local/bin" ]
  [ "$(printf '%s' "$out" | tr ':' '\n' | grep -cxF "$h/.local/bin")" -eq 1 ]
}

@test "rendered bashrc keeps exec fish last and tools no-op without micromamba/fnm" {
  render_server
  grep -q '^    exec fish' "$DEST/.bashrc"
  last_exec="$(grep -n 'exec fish' "$DEST/.bashrc" | tail -1 | cut -d: -f1)"
  for pat in 'micromamba shell hook' 'fnm env' 'bashrc.local'; do
    n="$(grep -n "$pat" "$DEST/.bashrc" | head -1 | cut -d: -f1)"
    [ "$n" -lt "$last_exec" ]
  done
  grep -q 'MAMBA_ROOT_PREFIX=' "$DEST/.bashrc"
  ! grep -q 'nvm' "$DEST/.bashrc"
  h="$(mktemp -d "${TMPDIR:-/tmp}/devenv-h.XXXXXX")"
  env -i HOME="$h" PATH="/usr/bin:/bin" bash --norc -i -c '. "$1"' _ "$DEST/.bashrc" </dev/null
}

@test "rendered fish files parse" {
  [ -n "$FISH" ] || skip "fish not available"
  render_server
  n=0
  while IFS= read -r f; do
    "$FISH" --no-execute "$f"
    n=$((n+1))
  done < <(find "$DEST/.config/fish" -name '*.fish')
  [ "$n" -ge 3 ]
}

@test "fish 10-env puts ~/.local/bin first once and survives missing tools" {
  [ -n "$FISH" ] || skip "fish not available"
  render_server
  h="$(mktemp -d "${TMPDIR:-/tmp}/devenv-h.XXXXXX")"
  out="$(env -i HOME="$h" PATH="/usr/bin:/bin:$h/.local/bin" \
    "$FISH" --no-config -c 'source $argv[1]; string join : $PATH' "$DEST/.config/fish/conf.d/10-env.fish")"
  [ "${out%%:*}" = "$h/.local/bin" ]
  [ "$(printf '%s' "$out" | tr ':' '\n' | grep -cxF "$h/.local/bin")" -eq 1 ]
}

@test "fish_plugins and config.fish are rendered" {
  render_server
  grep -qx 'ilancosman/tide@v6' "$DEST/.config/fish/fish_plugins"
  grep -q 'config.local.fish' "$DEST/.config/fish/config.fish"
}

@test "tmux conf loads" {
  command -v tmux >/dev/null || skip "tmux not available"
  render_server
  run tmux -L "devenv-t-$$" -f "$DEST/.tmux.conf" start-server \; kill-server
  [ "$status" -eq 0 ]
}

@test "vscode_remote_env.fish no longer sets GIT_ASKPASS" {
  render_server
  f="$DEST/.config/fish/conf.d/vscode_remote_env.fish"
  ! grep -q 'GIT_ASKPASS' "$f"
  grep -q 'VSCODE_IPC_HOOK_CLI' "$f"
  grep -q 'remote-cli' "$f"
}

@test "gitconfig includes ~/.gitconfig.local" {
  render_server
  run git config --file "$DEST/.gitconfig" --get include.path
  [ "$status" -eq 0 ]
  [ "$output" = "~/.gitconfig.local" ]
  run git config --file "$DEST/.gitconfig" --get user.email
  [ -n "$output" ]
  [ -f "$DEST/.config/git/ignore" ]
  [ -f "$DEST/.condarc" ]
}

# apply_over FIXTURE_NAME CONTENT: render into a destination pre-seeded with a file.
apply_seeded() {
  new_sandbox
  init_role server >&2
  printf '%s' "$2" > "$SB_DEST/$1"
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST" >&2
}

@test "tcshrc keeps existing content and gets one develop-env block" {
  orig=$'# Cadence\nsource /eda/cadence/setup.csh\nset prompt = "% "\n'
  apply_seeded .tcshrc "$orig"
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  f="$SB_DEST/.tcshrc"
  [ "$(grep -c '^# >>> develop-env >>>' "$f")" -eq 1 ]
  [ "$(grep -c '^# <<< develop-env <<<' "$f")" -eq 1 ]
  printf '%s' "$orig" > "$SB/orig"
  head -c "$(wc -c < "$SB/orig")" "$f" | cmp - "$SB/orig"
  [ "$(tail -1 "$f")" = "# <<< develop-env <<<" ]
  grep -q 'exec fish' "$f"
  grep -q '\$?prompt' "$f"
  grep -q '\.local/bin' "$f"
  # tcsh must accept the file when fish is absent (non-interactive: prompt unset)
  if command -v tcsh >/dev/null; then
    HOME="$SB_HOME" run tcsh -f -c "source $f; echo ok"
    [ "$status" -eq 0 ]
  fi
  # ~/.login is sourced right before exec fish, so .login-only setup reaches fish
  n_login="$(grep -n 'source ~/.login' "$f" | cut -d: -f1)"
  n_exec="$(grep -n '^ *exec fish$' "$f" | cut -d: -f1)"
  [ -n "$n_login" ] && [ "$n_login" -lt "$n_exec" ]
  grep -qF 'if ($?loginsh && -r ~/.login) source ~/.login' "$f"
  if command -v tcsh >/dev/null; then
    st="$SB/tstub"; mkdir -p "$st"
    printf '#!/bin/sh\nexit 0\n' > "$st/tty"
    printf '#!/bin/sh\necho "fish sees EDA_X=$EDA_X"\n' > "$st/fish"
    chmod +x "$st/tty" "$st/fish"
    printf 'setenv EDA_X from-login\n' > "$SB_HOME/.login"
    # only the managed block (the fixture's own lines source a missing /eda file)
    sed -n '/^# >>> develop-env >>>$/,/^# <<< develop-env <<<$/p' "$f" > "$SB/block.csh"
    # a login, interactive shell (loginsh and prompt set) with a terminal
    HOME="$SB_HOME" PATH="$st:/usr/bin:/bin" run tcsh -f -c "set loginsh; set prompt='% '; source $SB/block.csh"
    echo "$output"
    [[ "$output" == *"fish sees EDA_X=from-login"* ]]
    # not a login shell: ~/.login is left to tcsh
    HOME="$SB_HOME" PATH="$st:/usr/bin:/bin" run tcsh -f -c "set prompt='% '; source $SB/block.csh"
    [[ "$output" == *"fish sees EDA_X="* ]]
    [[ "$output" != *"from-login"* ]]
  fi
}

@test "MAMBA_ROOT_PREFIX follows \$HOME at runtime in bashrc and fish" {
  render_server
  grep -qx 'export MAMBA_ROOT_PREFIX="$HOME/micromamba"' "$DEST/.bashrc"
  grep -qx 'set -gx MAMBA_ROOT_PREFIX "$HOME/micromamba"' "$DEST/.config/fish/conf.d/10-env.fish"
  ! grep -qF "$(dirname "$DEST")/home/micromamba" "$DEST/.bashrc" "$DEST/.config/fish/conf.d/10-env.fish"
}

# zsh_apply SEED: apply ~/.zshrc (macOS only) on this Linux host from a source
# copy whose .chezmoiignore does not ignore it; SEED (may be empty: no file) is
# the existing ~/.zshrc. Sets ZF.
zsh_apply() {
  new_sandbox; init_role server >&2
  src="$SB/src"; mkdir -p "$src"
  cp -R "$REPO_ROOT/home" "$REPO_ROOT/lib" "$REPO_ROOT/ssh" "$REPO_ROOT/statusline" "$REPO_ROOT/.chezmoiroot" "$src/"
  sed -i 's/{{ if ne .chezmoi.os "darwin" }}/{{ if false }}/' "$src/home/.chezmoiignore"
  [ -z "$1" ] || printf '%s' "$1" > "$SB_DEST/.zshrc"
  HOME="$SB_HOME" XDG_CONFIG_HOME="$SB_HOME/.config" "$CHEZMOI" --config "$SB_CONFIG" --cache "$SB_CACHE" \
    --persistent-state "$SB_STATE" --source "$src" apply --exclude scripts --destination "$SB_DEST" "$SB_DEST/.zshrc" >&2
  ZF="$SB_DEST/.zshrc"
}

@test "macOS ~/.zshrc: created when absent, existing content kept, one block" {
  grep -q '^\.zshrc$' "$REPO_ROOT/home/.chezmoiignore"
  render_server
  [ ! -e "$DEST/.zshrc" ]   # not on Linux
  zsh_apply ""
  [ -f "$ZF" ]
  [ "$(grep -c '^# >>> develop-env >>>' "$ZF")" -eq 1 ]
  orig=$'export EDITOR=vim\n# >>> develop-env >>>\nstale\n# <<< develop-env <<<\nalias ll="ls -l"'
  zsh_apply "$orig"
  [ "$(head -1 "$ZF")" = "export EDITOR=vim" ]
  grep -qx 'alias ll="ls -l"' "$ZF"
  ! grep -qx stale "$ZF"
  [ "$(grep -c '^# >>> develop-env >>>' "$ZF")" -eq 1 ]
  [ "$(tail -1 "$ZF")" = "# <<< develop-env <<<" ]
  # Homebrew shellenv, fnm, ~/.local/bin first, then the exec fish guard last
  n_brew="$(grep -n 'brew shellenv' "$ZF" | head -1 | cut -d: -f1)"
  n_fnm="$(grep -n 'fnm env' "$ZF" | cut -d: -f1)"
  n_path="$(grep -n 'path=("$HOME/.local/bin"' "$ZF" | tail -1 | cut -d: -f1)"
  n_exec="$(grep -n 'exec fish' "$ZF" | cut -d: -f1)"
  [ "$n_brew" -lt "$n_fnm" ] && [ "$n_fnm" -lt "$n_path" ] && [ "$n_path" -lt "$n_exec" ]
  grep -q 'command -v fish' "$ZF"
  grep -q 'ZSH_EXECUTION_STRING' "$ZF"
  grep -q -- '-o interactive' "$ZF"
  if command -v zsh >/dev/null 2>&1; then zsh -n "$ZF"; fi
}

@test "tcshrc without trailing newline still gets a clean block" {
  apply_seeded .tcshrc 'source /eda/setup.csh'
  f="$SB_DEST/.tcshrc"
  [ "$(head -1 "$f")" = "source /eda/setup.csh" ]
  [ "$(grep -c '^# >>> develop-env >>>' "$f")" -eq 1 ]
}

@test "existing block is replaced in place of a stale one" {
  apply_seeded .tcshrc $'setenv A 1\n# >>> develop-env >>>\nstale\n# <<< develop-env <<<\nsetenv B 2\n'
  f="$SB_DEST/.tcshrc"
  ! grep -q '^stale$' "$f"
  [ "$(grep -c '^# >>> develop-env >>>' "$f")" -eq 1 ]
  grep -q '^setenv B 2$' "$f"
  [ "$(tail -1 "$f")" = "# <<< develop-env <<<" ]
}

@test "cshrc is managed only when tcshrc is absent" {
  apply_seeded .cshrc $'setenv A 1\n'
  [ "$(grep -c '^# >>> develop-env >>>' "$SB_DEST/.cshrc")" -eq 1 ]
  [ ! -e "$SB_DEST/.tcshrc" ]
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  [ "$(grep -c '^# >>> develop-env >>>' "$SB_DEST/.cshrc")" -eq 1 ]

  new_sandbox; init_role server >&2
  printf 'setenv A 1\n' > "$SB_DEST/.cshrc"
  printf 'setenv T 1\n' > "$SB_DEST/.tcshrc"
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  [ "$(cat "$SB_DEST/.cshrc")" = "setenv A 1" ]
  [ "$(grep -c '^# >>> develop-env >>>' "$SB_DEST/.tcshrc")" -eq 1 ]
}

@test "no tcshrc or cshrc: none created" {
  render_server
  [ ! -e "$DEST/.tcshrc" ]
  [ ! -e "$DEST/.cshrc" ]
}

@test "fish plugin script is rendered for the server with the tide flags" {
  new_sandbox; init_role server >&2
  run chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_20-fish-plugins.sh.tmpl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fisher update"* ]]
  [[ "$output" == *"tide configure --auto"* ]]
  [[ "$output" == *"--style=Classic"* ]]
  printf '%s\n' "$output" | sh -n
}

@test "hold data key reflects ~/.config/develop-env/hold" {
  new_sandbox
  init_role server >&2
  run chezmoi_iso execute-template '{{ .hold }}'
  [ "$output" = "false" ]
  mkdir -p "$SB_HOME/.config/develop-env"; : > "$SB_HOME/.config/develop-env/hold"
  init_role server >&2
  run chezmoi_iso execute-template '{{ .hold }}'
  [ "$output" = "true" ]
}

@test "doctor shell checks register" {
  # only the shell checks: the claude checks would query the real home's claude
  DOCTOR_ONLY='20-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"fish_present"* ]]
  [[ "$output" == *"tmux_version"* ]]
  [[ "$output" == *"git_user_email"* ]]
}

@test "hooks that prepend to PATH do not displace ~/.local/bin (bash)" {
  render_server
  h="$(mktemp -d "${TMPDIR:-/tmp}/devenv-h.XXXXXX")"; mkdir -p "$h/stub"
  printf '#!/bin/sh\necho "export PATH=/fake:\\$PATH"\n' > "$h/stub/fnm"; chmod +x "$h/stub/fnm"
  out="$(env -i HOME="$h" PATH="$h/stub:/usr/bin:/bin" \
    bash --norc -i -c '. "$1"; echo "$PATH"' _ "$DEST/.bashrc" </dev/null 2>/dev/null)"
  [[ "$out" == *"/fake:"* ]]
  [ "${out%%:*}" = "$h/.local/bin" ]
  [ "$(printf '%s' "$out" | tr ':' '\n' | grep -cxF "$h/.local/bin")" -eq 1 ]
}

@test "hooks that prepend to PATH do not displace ~/.local/bin (fish)" {
  [ -n "$FISH" ] || skip "fish not available"
  render_server
  h="$(mktemp -d "${TMPDIR:-/tmp}/devenv-h.XXXXXX")"; mkdir -p "$h/stub"
  printf '#!/bin/sh\necho "set -gx PATH /fake \\$PATH"\n' > "$h/stub/fnm"; chmod +x "$h/stub/fnm"
  out="$(env -i HOME="$h" PATH="$h/stub:/usr/bin:/bin" \
    "$FISH" --no-config -c 'source $argv[1]; string join : $PATH' "$DEST/.config/fish/conf.d/10-env.fish")"
  [[ "$out" == *"/fake:"* ]]
  [ "${out%%:*}" = "$h/.local/bin" ]
  [ "$(printf '%s' "$out" | tr ':' '\n' | grep -cxF "$h/.local/bin")" -eq 1 ]
}

@test "fish plugin script warns and exits 0 when fish fails" {
  new_sandbox; init_role server >&2
  h="$SB/h"; mkdir -p "$h/stub"
  printf '#!/bin/sh\nexit 1\n' > "$h/stub/fish"; chmod +x "$h/stub/fish"
  chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_20-fish-plugins.sh.tmpl" > "$SB/script.sh"
  run env -i HOME="$h" PATH="$h/stub:/usr/bin:/bin" sh "$SB/script.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning:"* ]]
  grep -q -- '--max-time 30' "$SB/script.sh"
  # the failure leaves a retry marker, which changes the next render (chezmoi reruns it)
  [ -e "$h/.local/state/develop-env/retry/20-fish-plugins" ]
  grep -qx '# retry: ' "$SB/script.sh"
  mkdir -p "$SB_HOME/.local/state/develop-env/retry"; : > "$SB_HOME/.local/state/develop-env/retry/20-fish-plugins"
  chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_20-fish-plugins.sh.tmpl" > "$SB/again.sh"
  grep -qx '# retry: retry' "$SB/again.sh"
  # fish missing altogether: also a retry
  rm -f "$h/.local/state/develop-env/retry/20-fish-plugins" "$h/stub/fish"
  run env -i HOME="$h" PATH="$h/stub:/usr/bin:/bin" sh "$SB/script.sh"
  [ "$status" -eq 0 ]
  [ -e "$h/.local/state/develop-env/retry/20-fish-plugins" ]
  # success removes it
  printf '#!/bin/sh\nexit 0\n' > "$h/stub/fish"; chmod +x "$h/stub/fish"
  run env -i HOME="$h" PATH="$h/stub:/usr/bin:/bin" sh "$SB/script.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$h/.local/state/develop-env/retry/20-fish-plugins" ]
}
