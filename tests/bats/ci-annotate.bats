#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../ci-annotate.sh"
  TAP="$BATS_TEST_TMPDIR/bats.out"
}

@test "two not-ok blocks yield two escaped ::error lines" {
  printf '%s\r\n' '1..3' \
    'ok 1 fine' \
    'not ok 2 first failure' \
    '# (in test file a.bats, line 5)' \
    '#   `[ "$x" = 100% ]'"'"' failed' \
    'ok 3 fine again' > "$TAP"
  printf '%s\n' 'not ok 4 second failure' '# boom' '# bang' >> "$TAP"
  run "$SCRIPT" "$TAP" "bats host"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "::error title=bats host::not ok 2 first failure%0D%0A"* ]] || [[ "${lines[0]}" == "::error title=bats host::not ok 2 first failure"* ]]
  [[ "${lines[0]}" == *"%0A# (in test file a.bats, line 5)"* ]]
  [[ "${lines[0]}" == *"100%25 ]"* ]]
  [ "${lines[1]}" = "::error title=bats host::not ok 4 second failure%0A# boom%0A# bang" ]
}

@test "passing TAP emits nothing" {
  printf '%s\n' '1..2' 'ok 1 a' 'ok 2 b # skip why' > "$TAP"
  run "$SCRIPT" "$TAP" "bats host"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "diagnostics capped at 15 lines and annotations at 10" {
  : > "$TAP"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'not ok %s t\n' "$i" >> "$TAP"
    for j in $(seq 1 20); do printf '# d%s\n' "$j" >> "$TAP"; done
  done
  run "$SCRIPT" "$TAP" t
  [ "${#lines[@]}" -eq 10 ]
  [[ "${lines[0]}" == *"%0A# d15" ]]
}

@test "bootstrap annotations: one per doctor FAIL plus the bootstrap tail" {
  cd "$BATS_TEST_TMPDIR"
  printf 'PASS a\r\nFAIL b: broken\nWARN c: meh\n' > doctor.out
  printf 'line %s\n' 1 2 3 > bootstrap.out
  run "$BATS_TEST_DIRNAME/../ci-annotate-bootstrap.sh" "macOS bootstrap"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "::error title=macOS bootstrap::not ok doctor FAIL b%3A broken" ] || [ "${lines[0]}" = "::error title=macOS bootstrap::not ok doctor FAIL b: broken" ]
  [[ "${lines[1]}" == *"not ok bootstrap output (last 15 lines)%0A# line 1%0A# line 2%0A# line 3" ]]
}

@test "bootstrap annotations include the install script warnings" {
  cd "$BATS_TEST_TMPDIR"
  : > doctor.out
  printf 'ok\n\033[33;1mWARNING: could not fetch obra/superpowers at v1\033[0m\nwarning: codex install failed\nok\n' > bootstrap.out
  run "$BATS_TEST_DIRNAME/../ci-annotate-bootstrap.sh" "Windows bootstrap"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not ok install script warnings (last 40)%0A# WARNING%3A could not fetch obra/superpowers at v1%0A# warning%3A codex install failed"* ]] \
    || [[ "$output" == *"not ok install script warnings (last 40)%0A# WARNING: could not fetch obra/superpowers at v1%0A# warning: codex install failed"* ]]
}
