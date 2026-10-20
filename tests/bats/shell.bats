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
  run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"fish_present"* ]]
  [[ "$output" == *"tmux_version"* ]]
  [[ "$output" == *"git_user_email"* ]]
}
