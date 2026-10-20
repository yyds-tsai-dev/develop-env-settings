#!/usr/bin/env bats

load helpers

setup() { new_sandbox; HOST_OS="$(uname -s)"; }
teardown() { rm -rf "$SB"; }

is_linux() { [ "$HOST_OS" = Linux ]; }
is_darwin() { [ "$HOST_OS" = Darwin ]; }
is_windows() { case "$HOST_OS" in MINGW*|MSYS*|CYGWIN*) return 0;; *) return 1;; esac; }

@test "role server sets isServer" {
  is_linux || is_darwin || skip "server role needs linux or darwin"
  run init_role server
  [ "$status" -eq 0 ]
  run chezmoi_iso execute-template '{{ .isServer }}'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "role desktop is accepted on darwin and windows" {
  is_darwin || is_windows || skip "needs darwin or windows host"
  run init_role desktop
  [ "$status" -eq 0 ]
  run chezmoi_iso execute-template '{{ .isDesktop }}-{{ .isServer }}'
  [ "$output" = "true-false" ]
}

@test "role desktop+server is accepted on darwin" {
  is_darwin || skip "needs darwin host"
  run init_role "desktop+server"
  [ "$status" -eq 0 ]
  run chezmoi_iso execute-template '{{ .isDesktop }}-{{ .isServer }}'
  [ "$output" = "true-true" ]
}

@test "role desktop on linux is rejected" {
  is_linux || skip "linux-only assertion"
  run init_role desktop
  [ "$status" -ne 0 ]
  [[ "$output" == *"desktop role needs windows or darwin"* ]]
}

@test "role desktop+server off darwin is rejected" {
  is_darwin && skip "non-darwin assertion"
  run init_role "desktop+server"
  [ "$status" -ne 0 ]
  [[ "$output" == *"desktop+server role needs darwin"* ]]
}

@test "role server on windows is rejected" {
  is_windows || skip "windows-only assertion"
  run init_role server
  [ "$status" -ne 0 ]
  [[ "$output" == *"server role needs linux"* ]]
}

@test "unknown role is rejected on every OS" {
  run init_role bogus
  [ "$status" -ne 0 ]
}

@test "nfs home sets sharedHome only when ci fake fstype says so" {
  is_linux || skip "linux-only"
  CI=true DEVENV_FAKE_FSTYPE=nfs4 run init_role server
  [ "$status" -eq 0 ]
  run chezmoi_iso execute-template '{{ .sharedHome }}-{{ .ci }}'
  [ "$output" = "true-true" ]
}

@test "render_home renders files and does not touch the real home" {
  is_linux || is_darwin || skip "server render needs linux or darwin"
  REAL_HOME="$HOME"
  touch "$SB/marker"
  sleep 1
  run render_home server
  [ "$status" -eq 0 ]
  dest="${lines[${#lines[@]}-1]}"
  [ -f "$dest/.config/develop-env/README" ]
  [ -z "$(find "$REAL_HOME" -maxdepth 3 -newer "$SB/marker" -not -path "$SB/*" -not -path "$REAL_HOME/.claude*" -not -path "$REAL_HOME/.codex*" 2>/dev/null | head -n1)" ]
}

@test "no managed file contains an absolute home path" {
  cd "$REPO_ROOT"
  dirs=()
  for d in home lib bin doctor.d; do [ -d "$d" ] && dirs+=("$d"); done
  [ "${#dirs[@]}" -ge 1 ]
  run grep -rE '/ldaphome|/home/[a-z]|/Users/|/root/|C:\\Users' "${dirs[@]}"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "doctor exits 0 with only core checks" {
  run "$REPO_ROOT/bin/doctor" --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS chezmoi_present"* ]]
}
