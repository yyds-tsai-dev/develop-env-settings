#!/usr/bin/env bats

load helpers

setup() { new_sandbox; }
teardown() { rm -rf "$SB"; }

@test "role server sets isServer" {
  case "$(uname -s)" in Linux|Darwin) ;; *) skip "server role needs linux or darwin";; esac
  run init_role server linux
  [ "$status" -eq 0 ]
  run chezmoi_iso execute-template '{{ .isServer }}'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "role desktop on linux is rejected" {
  [ "$(uname -s)" = Linux ] || skip "linux-only assertion"
  run init_role desktop linux
  [ "$status" -ne 0 ]
  [[ "$output" == *"desktop role needs windows or darwin"* ]]
}

@test "role desktop+server off darwin is rejected" {
  [ "$(uname -s)" != Darwin ] || skip "non-darwin assertion"
  run init_role "desktop+server" linux
  [ "$status" -ne 0 ]
  [[ "$output" == *"desktop+server role needs darwin"* ]]
}

@test "nfs home sets sharedHome only when ci fake fstype says so" {
  [ "$(uname -s)" = Linux ] || skip "linux-only"
  CI=true DEVENV_FAKE_FSTYPE=nfs4 run init_role server linux
  [ "$status" -eq 0 ]
  run chezmoi_iso execute-template '{{ .sharedHome }}-{{ .ci }}'
  [ "$output" = "true-true" ]
}

@test "render_home produces a destination without touching real home" {
  [ "$(uname -s)" = Linux ] || skip "linux-only"
  before="$(ls -A "$HOME" | wc -l)"
  run render_home server linux
  [ "$status" -eq 0 ]
  [ "$(ls -A "$HOME" | wc -l)" = "$before" ]
}

@test "no managed file contains an absolute home path" {
  run bash -c "cd '$REPO_ROOT' && grep -rE '/ldaphome|/home/[a-z]' home/ lib/ bin/ doctor.d/"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "doctor exits 0 with only core checks" {
  run "$REPO_ROOT/bin/doctor" --ci
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS chezmoi_present"* ]]
}
