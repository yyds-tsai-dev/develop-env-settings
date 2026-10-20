#!/usr/bin/env bats
# bin/capture against a copy of the repo and a fake HOME under /tmp. claude, uv,
# micromamba and chezmoi are stubs on PATH; the real home is never read.

load helpers

setup() {
  new_sandbox
  command -v uv >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no uv or python3"
  command -v git >/dev/null 2>&1 || skip "git not installed"
  REPO="$SB/repo"; STUB="$SB/stub"
  mkdir -p "$REPO/bin" "$REPO/lib" "$REPO/home/.chezmoidata" "$STUB"
  cp "$REPO_ROOT/bin/capture" "$REPO/bin/"
  cp "$REPO_ROOT/lib/capture_manifest.py" "$REPO/lib/"
  cp "$REPO_ROOT/home/.chezmoidata/"*.yaml "$REPO/home/.chezmoidata/"
  git -C "$REPO" init -q
  git -C "$REPO" -c user.name=t -c user.email=t@example.com add -A
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -qm base
  HEAD0="$(git -C "$REPO" rev-parse HEAD)"

  stub chezmoi 'exit 0'
  stub claude 'case "$*" in
  "plugin marketplace list") printf "Configured marketplaces:\n\n  ❯ claude-plugins-official\n    Source: GitHub (anthropics/claude-plugins-official)\n\n  ❯ newmkt\n    Source: GitHub (acme/newmkt)\n" ;;
  "plugin list") printf "Installed plugins:\n\n  ❯ superpowers@claude-plugins-official\n    Version: 1\n    Status: enabled\n\n  ❯ extra@newmkt\n    Version: 2\n" ;;
  *) exit 1 ;;
esac'
  stub micromamba 'printf "name: x\nchannels:\n  - conda-forge\ndependencies:\n  - conda-forge::fzf\n  - jq=1.7\n  - htop\n"'
  mkdir -p "$SB_HOME/.vscode-server/extensions/ms-python.python-2024.1.0-linux-x64" \
           "$SB_HOME/.vscode-server/extensions/Foo.Bar-1.2.3" \
           "$SB_HOME/.vscode-server/extensions/Foo.Bar-1.2.4"
  echo '[]' > "$SB_HOME/.vscode-server/extensions/extensions.json"
}
teardown() { rm -rf "$SB"; }

# stub NAME BODY: executable stub script on the stub PATH. uv is special: a
# `uv run --script` call is forwarded to the real uv/python so the capture script runs.
stub() {
  printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"
}

run_capture() {
  if command -v uv >/dev/null 2>&1; then
    # real uv runs the script; the stub is only reachable as `uv tool list`
    REAL_UV="$(command -v uv)"
    stub uv "if [ \"\$1\" = run ]; then exec $REAL_UV \"\$@\"; fi
if [ \"\$1 \$2\" = \"tool list\" ]; then printf 'semble v0.5.5\n- semble\nnewtool v1.0\n- newtool\n'; else exit 1; fi"
  fi
  HOME="$SB_HOME" PATH="$STUB:$PATH" run bash "$REPO/bin/capture"
}

@test "capture rewrites extension list from fake vscode-server dir" {
  run_capture
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/desktop/vscode/server-extensions.txt")" = "$(printf 'foo.bar\nms-python.python')" ]
}

@test "capture leaves the repo uncommitted" {
  run_capture
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD0" ]
  [[ "$output" == *"git diff --stat"* ]]
  [ -n "$(git -C "$REPO" status --porcelain)" ]
}

@test "capture changes manifest membership only and keeps comments and the lock" {
  run_capture
  [ "$status" -eq 0 ]
  m="$REPO/home/.chezmoidata/manifest.yaml"
  grep -q 'name: newtool' "$m"
  grep -q 'name: htop' "$m"
  grep -q 'name: "extra@newmkt"' "$m"
  grep -q 'name: newmkt, source: none, repo: acme/newmkt' "$m"
  ! grep -q 'name: graphifyy' "$m"          # not in uv tool list
  ! grep -q 'name: tmux' "$m"             # linux entry absent from the env is removed
  grep -q 'builtin: true' "$m"              # builtin marketplace kept
  grep -q '3.12: the newest CPython' "$m"   # comments intact
  git -C "$REPO" diff --quiet -- home/.chezmoidata/versions.yaml
}

@test "capture skips a section whose tool is missing instead of emptying it" {
  rm "$STUB/micromamba" "$STUB/claude"
  # no real micromamba/claude on a clean PATH is not guaranteed; hide them
  printf '#!/bin/sh\nexit 127\n' > "$STUB/micromamba"; chmod +x "$STUB/micromamba"
  cp "$STUB/micromamba" "$STUB/claude"
  run_capture
  [ "$status" -eq 0 ]
  grep -q 'name: fzf' "$REPO/home/.chezmoidata/manifest.yaml"
  grep -q 'name: "superpowers@claude-plugins-official"' "$REPO/home/.chezmoidata/manifest.yaml"
}
