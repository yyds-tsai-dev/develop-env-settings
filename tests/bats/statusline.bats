#!/usr/bin/env bats
# Host-side tests for the status line install script. Sandbox HOME, stubbed
# curl/go/uname; nothing touches the network or the real $HOME.

load helpers

setup() {
  [ "$(uname -s)" = Linux ] || skip "linux install script"
  new_sandbox
  H="$SB_HOME"; STUB="$SB/stub"; mkdir -p "$STUB" "$H/.claude"
  printf '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; *) echo Linux;; esac\n' > "$STUB/uname"
  chmod +x "$STUB/uname"
}
teardown() { rm -rf "$SB"; }

# render_with LOCK: render the script with the statusline lock set (empty = none).
render_with() {
  init_role server >&2
  local data="$SB/data.yaml"
  if [ -n "$1" ]; then
    # --override-data is not available for execute-template; wrap the template instead.
    { printf '{{ $_ := set .versions "statusline" "%s" }}' "$1"; cat "$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_60-statusline.sh.tmpl"; } \
      | chezmoi_iso execute-template > "$SB/sl.sh"
  else
    chezmoi_iso execute-template < "$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_60-statusline.sh.tmpl" > "$SB/sl.sh"
  fi
  sh -n "$SB/sl.sh"
}

# Run the script with only the stubs and system essentials on PATH.
run_sl() {
  # keep sh/mkdir/chmod/mv/rm; hide any real go/curl by using a minimal PATH of stubs + coreutils symlinks
  mkdir -p "$SB/bin"
  for t in sh mkdir chmod mv rm cat dirname; do ln -sf "$(command -v $t)" "$SB/bin/$t"; done
  HOME="$H" PATH="$STUB:$SB/bin" run /bin/sh "$SB/sl.sh"
}

@test "lock present: downloads the matching release asset" {
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; http*) echo "$1" >> "%s/urls";; esac; shift; done\necho bin > "$out"\n' "$SB" > "$STUB/curl"
  chmod +x "$STUB/curl"
  render_with 0.1.0
  run_sl
  [ "$status" -eq 0 ]
  [ "$(cat "$SB/urls")" = "https://github.com/yyds-tsai-dev/develop-env-settings/releases/download/statusline-v0.1.0/statusline-linux-amd64" ]
  [ -x "$H/.claude/statusline-bin" ]
}

@test "no lock, go present: builds locally" {
  printf '#!/bin/sh\necho "$@" > "%s/goargs"\npwd > "%s/gopwd"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && echo built > "$2"; shift; done\n' "$SB" "$SB" > "$STUB/go"
  chmod +x "$STUB/go"
  printf '#!/bin/sh\necho curl called >> "%s/urls"; exit 22\n' "$SB" > "$STUB/curl"; chmod +x "$STUB/curl"
  render_with ""
  run_sl
  [ "$status" -eq 0 ]
  [ ! -e "$SB/urls" ]
  grep -q "build" "$SB/goargs"
  grep -q "$H/.claude/statusline-bin" "$SB/goargs"
  [ "$(basename "$(cat "$SB/gopwd")")" = statusline ]
  [ "$(cat "$H/.claude/statusline-bin")" = built ]
}

@test "no lock, no go: warns and exits 0" {
  render_with ""
  run_sl
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]]
  [ ! -e "$H/.claude/statusline-bin" ]
}

@test "statusline source and release workflow are in place" {
  [ -f "$REPO_ROOT/statusline/main.go" ] && [ -f "$REPO_ROOT/statusline/go.mod" ]
  [ ! -e "$REPO_ROOT/statusline/build.sh" ]
  grep -q "statusline-v\*" "$REPO_ROOT/.github/workflows/statusline-release.yml"
  grep -q "CGO_ENABLED" "$REPO_ROOT/.github/workflows/statusline-release.yml"
}
