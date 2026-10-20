#!/usr/bin/env bats
# SSH key step and authorized_keys render. Sandbox HOMEs under /tmp only; a stub
# `ssh` replaces the network call.

load helpers

setup() {
  new_sandbox
  STUB="$SB/stub"; mkdir -p "$STUB"
  command -v ssh-keygen >/dev/null 2>&1 || skip "ssh-keygen not installed"
}
teardown() { rm -rf "$SB"; }

stub_ssh() {  # stub_ssh TEXT: fake `ssh` that prints TEXT and exits 1 (like github)
  printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$1" > "$STUB/ssh"; chmod +x "$STUB/ssh"
}

# mode_is MODE PATH: GNU or BSD stat; Git Bash on Windows has no Unix modes, so
# the check is skipped there.
mode_is() {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  [ "$(stat -c %a "$2" 2>/dev/null || stat -f %Lp "$2")" = "$1" ]
}

run_key() { HOME="$SB_HOME" PATH="$STUB:$PATH" run bash "$REPO_ROOT/lib/ssh-key.sh" "$@"; }

@test "ssh-key creates the key once and never overwrites it" {
  stub_ssh "Hi u! You've successfully authenticated, but GitHub does not provide shell access."
  run_key --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://github.com/settings/ssh/new"* ]]
  [[ "$output" == *"GitHub SSH authentication works"* ]]
  fp1="$(ssh-keygen -lf "$SB_HOME/.ssh/id_ed25519.pub")"
  mode_is 700 "$SB_HOME/.ssh"
  run_key --ci
  [ "$status" -eq 0 ]
  [[ "$output" != *"Created"* ]]
  [ "$fp1" = "$(ssh-keygen -lf "$SB_HOME/.ssh/id_ed25519.pub")" ]
}

@test "ssh-key warns, exits 0 and does not wait when GitHub rejects the key" {
  stub_ssh "git@github.com: Permission denied (publickey)."
  run_key </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: GitHub SSH authentication failed"* ]]
}

@test "ssh-key leaves an existing key alone" {
  mkdir -p "$SB_HOME/.ssh"
  echo private > "$SB_HOME/.ssh/id_ed25519"
  stub_ssh "nope"
  run_key --ci
  [ "$status" -eq 0 ]
  [ "$(cat "$SB_HOME/.ssh/id_ed25519")" = private ]
  [ ! -e "$SB_HOME/.ssh/id_ed25519.pub" ]
}

@test "doctor ssh_key fails without a key, passes with one; github auth skips in ci" {
  HOME="$SB_HOME" DOCTOR_ONLY='40-*' run "$REPO_ROOT/bin/doctor" --ci
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL ssh_key"* ]]
  [[ "$output" == *"SKIP github_ssh_auth"* ]]
  mkdir -p "$SB_HOME/.ssh"; touch "$SB_HOME/.ssh/id_ed25519.pub"
  HOME="$SB_HOME" DOCTOR_ONLY='40-*' run "$REPO_ROOT/bin/doctor" --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS ssh_key"* ]]
}

render_server() {
  case "$(uname -s)" in Linux) ;; *) skip "server render needs linux" ;; esac
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  init_role server >&2
}

@test "authorized_keys is created with mode 600 in a 700 .ssh when absent" {
  render_server
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  f="$SB_DEST/.ssh/authorized_keys"
  [ -f "$f" ]
  mode_is 600 "$f"
  mode_is 700 "$SB_DEST/.ssh"
  grep -qF "$(cut -d' ' -f2 "$REPO_ROOT/ssh/authorized_keys.pub-list" | head -n1)" "$f"
}

@test "authorized_keys keeps existing lines and does not duplicate the key" {
  render_server
  mkdir -p "$SB_DEST/.ssh"; chmod 700 "$SB_DEST/.ssh"
  printf 'ssh-rsa AAAAB3other keep-me' > "$SB_DEST/.ssh/authorized_keys"
  chmod 600 "$SB_DEST/.ssh/authorized_keys"
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  f="$SB_DEST/.ssh/authorized_keys"
  [ "$(head -n1 "$f")" = "ssh-rsa AAAAB3other keep-me" ]
  [ "$(wc -l < "$f")" -eq 2 ]
  mode_is 600 "$f"
}

@test "authorized_keys merge falls back to python3 when uv is absent" {
  case "$(uname -s)" in Linux) ;; *) skip "server render needs linux" ;; esac
  [ -x /usr/bin/python3 ] || skip "no /usr/bin/python3"
  [ ! -e /usr/bin/uv ] && [ ! -e /bin/uv ] || skip "host has a system uv"
  init_role server >&2
  PATH=/usr/bin:/bin run chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qF "$(cut -d' ' -f2 "$REPO_ROOT/ssh/authorized_keys.pub-list" | head -n1)" "$SB_DEST/.ssh/authorized_keys"
}

@test "desktop role does not manage authorized_keys" {
  case "$(uname -s)" in Darwin) ;; *) skip "desktop render needs macOS/Windows host" ;; esac
  init_role desktop >&2
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
  [ ! -e "$SB_DEST/.ssh/authorized_keys" ]
}
