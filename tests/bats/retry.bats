#!/usr/bin/env bats
# Retry markers (home/.chezmoitemplates/retry-marker, retry-sh, retry-ps1): a
# failed install script writes a fresh nonce into
# ~/.local/state/develop-env/retry/<name>; the script renders it in its
# "# retry:" line, so every failed run changes the script and chezmoi reruns it
# on the next apply. Sandboxes under the temp dir; stubs only, no network.

load helpers

setup() {
  new_sandbox
  H="$SB/h"; STUB="$SB/stub"; mkdir -p "$H" "$STUB"
}
teardown() { rm -rf "$SB"; }

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

# render SCRIPT_BASENAME: render a home/.chezmoiscripts template for the server role.
render() {
  init_role server >&2
  chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/$1" > "$SB/$1.out"
  echo "$SB/$1.out"
}

# marker NAME: the nonce in $H's marker for NAME (empty when there is none).
marker() { cat "$H/.local/state/develop-env/retry/$1" 2>/dev/null; }

@test "a script that always fails runs on every apply; after a success it stops" {
  case "$(uname -s)" in Linux|Darwin) ;; *) skip "sh install script; unix hosts" ;; esac
  # A minimal source dir with the shipped helper templates and one script whose
  # install step is a stub that fails until $HOME/ok exists.
  src="$SB/src"; mkdir -p "$src/.chezmoiscripts"
  cp -R "$REPO_ROOT/home/.chezmoitemplates" "$src/.chezmoitemplates"
  cat > "$src/.chezmoiscripts/run_onchange_after_99-test.sh.tmpl" <<'EOF'
#!/bin/sh
{{ template "retry-marker" (dict "chezmoi" .chezmoi "name" "99-test") }}
{{ template "retry-sh" "99-test" }}
echo run >> "$HOME/runs"
if "$HOME/stub/install"; then retry_clear; else retry_mark; fi
exit 0
EOF
  mkdir -p "$SB_HOME/stub"
  printf '#!/bin/sh\n[ -e "$HOME/ok" ]\n' > "$SB_HOME/stub/install"; chmod +x "$SB_HOME/stub/install"
  apply() {
    HOME="$SB_HOME" USERPROFILE="$SB_HOME" XDG_CONFIG_HOME="$SB_HOME/.config" \
      "$CHEZMOI" --config "$SB_CONFIG" --cache "$SB_CACHE" --persistent-state "$SB_STATE" \
      --source "$src" --destination "$SB_DEST" --no-tty apply </dev/null
  }
  runs() { grep -c . "$SB_HOME/runs" 2>/dev/null || echo 0; }
  for i in 1 2 3 4; do
    apply
    [ "$(runs)" -eq "$i" ] || { echo "apply $i: $(runs) runs"; false; }
    [ -s "$SB_HOME/.local/state/develop-env/retry/99-test" ]
  done
  touch "$SB_HOME/ok"
  apply   # renders the last nonce: runs, succeeds, deletes the marker
  [ "$(runs)" -eq 5 ]
  [ ! -e "$SB_HOME/.local/state/develop-env/retry/99-test" ]
  apply   # the render went nonce -> empty: runs once more (harmless)
  [ "$(runs)" -eq 6 ]
  apply   # nothing pending: does not run
  apply
  [ "$(runs)" -eq 6 ]
}

@test "every install script that downloads or installs carries a retry marker" {
  cd "$REPO_ROOT/home/.chezmoiscripts"
  for f in run_onchange_*; do
    grep -qE 'curl |Invoke-WebRequest|"\$BREW" install|uv tool install|npm install|fish -c' "$f" || continue
    grep -q '{{ template "retry-marker" (dict "chezmoi" .chezmoi "name" ' "$f" || { echo "$f: no retry-marker line"; false; }
    case "$f" in
      *.ps1.tmpl) grep -q '{{ template "retry-ps1" ' "$f" && grep -q 'Set-RetryMarker' "$f" && grep -q 'Clear-RetryMarker' "$f" ;;
      *) grep -q '{{ template "retry-sh" ' "$f" && grep -q 'retry_mark' "$f" && grep -q 'retry_clear' "$f" ;;
    esac || { echo "$f: does not write and clear its marker"; false; }
  done
  # the old constant marker is gone
  ! grep -l 'retry{{ end }}' run_*
}

@test "retry-sh writes a different nonce on every failure, and the render shows it" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render run_onchange_after_30-uv-tools.sh.tmpl)"
  grep -qx '# retry: ' "$f"
  stub uv 'exit 1'
  HOME="$H" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bin/update retries"* ]]
  n1="$(marker 30-uv-tools)"; [ -n "$n1" ]
  HOME="$H" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  n2="$(marker 30-uv-tools)"; [ -n "$n2" ] && [ "$n2" != "$n1" ]
  mkdir -p "$SB_HOME/.local/state/develop-env/retry"; printf '%s\n' "$n2" > "$SB_HOME/.local/state/develop-env/retry/30-uv-tools"
  f2="$(render run_onchange_after_30-uv-tools.sh.tmpl)"
  grep -qxF "# retry: $n2" "$f2"
  # macOS-style date (no %N): falls back to seconds plus the PID
  printf '#!/bin/sh\ncase "$1" in +%%s%%N) echo 1700000000N ;; *) echo 1700000000 ;; esac\n' > "$STUB/date"; chmod +x "$STUB/date"
  HOME="$H" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  [[ "$(marker 30-uv-tools)" =~ ^1700000000\.[0-9]+$ ]]
  # success clears it
  stub uv 'exit 0'
  HOME="$H" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  [ "$status" -eq 0 ]
  [ -z "$(marker 30-uv-tools)" ]
}

@test "micromamba, node and statusline scripts leave a retry marker when downloads fail" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  stub curl 'exit 22'
  for s in 10-micromamba-envs 20-node 60-statusline; do
    f="$(render "run_onchange_after_$s.sh.tmpl")"
    grep -qx '# retry: ' "$f"
    HOME="$H" PATH="$STUB:/usr/bin:/bin" run sh "$f"
    echo "$s: $output"
    [ "$status" -eq 0 ]
    [ -n "$(marker "$s")" ] || { echo "$s left no marker"; false; }
  done
  # 15-symlinks renders 10-micromamba-envs' marker, so it reruns with that retry
  mkdir -p "$SB_HOME/.local/state/develop-env/retry"; echo 42 > "$SB_HOME/.local/state/develop-env/retry/10-micromamba-envs"
  f="$(render run_onchange_after_15-symlinks.sh.tmpl)"
  grep -qx '# retry: 42' "$f"
}

@test "statusline: a successful release download clears the marker" {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  f="$(render run_onchange_after_60-statusline.sh.tmpl)"
  mkdir -p "$H/.local/state/develop-env/retry"; echo 1 > "$H/.local/state/develop-env/retry/60-statusline"
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done\necho bin > "$out"\n' > "$STUB/curl"; chmod +x "$STUB/curl"
  printf '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n' > "$STUB/uname"; chmod +x "$STUB/uname"
  HOME="$H" PATH="$STUB:/usr/bin:/bin" run sh "$f"
  [ "$status" -eq 0 ]
  [ -x "$H/.claude/statusline-bin" ]
  [ -z "$(marker 60-statusline)" ]
}
