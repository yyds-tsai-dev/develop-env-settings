#!/usr/bin/env bats

load helpers

setup() { new_sandbox; HOST_OS="$(uname -s)"; }
teardown() { chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"; }

is_linux() { [ "$HOST_OS" = Linux ]; }
is_darwin() { [ "$HOST_OS" = Darwin ]; }
is_windows() { case "$HOST_OS" in MINGW*|MSYS*|CYGWIN*) return 0;; *) return 1;; esac; }

@test "role server sets isServer" {
  is_linux || skip "server role needs linux"
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

@test "role server off linux is rejected" {
  is_linux && skip "non-linux assertion"
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
  is_linux || skip "server render needs linux"
  REAL_HOME="$HOME"
  touch "$SB/marker"
  sleep 1
  run render_home server
  [ "$status" -eq 0 ]
  dest="${lines[${#lines[@]}-1]}"
  [ -f "$dest/.config/develop-env/README" ]
  touched="$(find "$REAL_HOME" -mindepth 1 -maxdepth 3 -type f -newer "$SB/marker" -not -path "$SB/*" -not -path "$REAL_HOME/.claude*" -not -path "$REAL_HOME/.codex*" 2>/dev/null | head -n3)"
  [ -z "$touched" ] || { echo "real home touched: $touched" >&2; false; }
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
  DOCTOR_ONLY='00-*' run "$REPO_ROOT/bin/doctor" --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS chezmoi_present"* ]]
}

# bootstrap_urls MACHINE [chezmoi]: run bootstrap.sh in the sandbox with uname
# faking Linux MACHINE and a curl that logs its URL and fails; with "chezmoi",
# a stub chezmoi is on PATH so the uv download is reached. Echoes the URL log.
bootstrap_urls() {
  local stub="$SB/stub"; mkdir -p "$stub"; rm -f "$stub/chezmoi"
  printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo %s ;; *) echo Linux ;; esac\n' "$1" > "$stub/uname"
  # curl -w (the releases/latest redirect lookup) answers a tag; every download fails
  printf '#!/bin/sh\nfor a; do case "$a" in https://*) echo "$a" >> "%s/urls" ;; esac; done\ncase " $* " in *" -w "*) printf %%s https://github.com/twpayne/chezmoi/releases/tag/v9.8.7; exit 0 ;; esac\nexit 22\n' "$SB" > "$stub/curl"
  [ "${2:-}" = chezmoi ] && printf '#!/bin/sh\nexit 0\n' > "$stub/chezmoi"
  chmod +x "$stub"/*
  : > "$SB/urls"
  HOME="$SB_HOME" PATH="$stub:/usr/bin:/bin" sh "$REPO_ROOT/bootstrap.sh" --source "$REPO_ROOT" --ci >/dev/null 2>&1 || true
  cat "$SB/urls"
}

@test "bootstrap downloads the static musl chezmoi and uv builds on Linux" {
  is_windows && skip "bootstrap.sh is the Linux and macOS path"
  PATH="/usr/bin:/bin" command -v chezmoi >/dev/null 2>&1 && skip "a system chezmoi would skip the download"
  PATH="/usr/bin:/bin" command -v uv >/dev/null 2>&1 && skip "a system uv would skip the download"
  run bootstrap_urls x86_64
  echo "$output"
  [ "$output" = "https://github.com/twpayne/chezmoi/releases/latest/download/chezmoi-linux-amd64-musl" ]
  run bootstrap_urls x86_64 chezmoi
  echo "$output"
  [ "$output" = "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-musl.tar.gz" ]
  run bootstrap_urls aarch64 chezmoi
  [ "$output" = "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-musl.tar.gz" ]
  # linux-arm64 chezmoi: only the versioned release tarball exists
  run bootstrap_urls aarch64
  echo "$output"
  [ "$output" = "https://github.com/twpayne/chezmoi/releases/latest
https://github.com/twpayne/chezmoi/releases/download/v9.8.7/chezmoi_9.8.7_linux_arm64.tar.gz" ]
  ! grep -q 'linux-gnu' "$REPO_ROOT/bootstrap.sh"
  grep -qF 'cos=linux-musl' "$REPO_ROOT/tests/setup-tools.sh"
}
