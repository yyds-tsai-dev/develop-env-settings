#!/usr/bin/env bats
# Bitwarden-backed Secrets. A stub `bw` on PATH answers `status`, `list folders`
# and `list items`; all values are fake. Sandboxes live under /tmp only.

load helpers

ENVFILE=".config/paper-search-mcp/.env"

setup() {
  new_sandbox
  STUB="$SB/stub"; mkdir -p "$STUB"
  init_role server >&2
}
teardown() { rm -rf "$SB"; }

# stub_bw STATUS: fake `bw` reporting STATUS (unlocked|locked|unauthenticated).
stub_bw() {
  cat > "$STUB/bw" <<STUBEOF
#!/bin/sh
case "\$1 \$2" in
  "status "*) echo '{"status":"$1"}' ;;
  "list folders") echo '[{"id":"fld1","name":"develop-env-settings"}]' ;;
  "list items")
    case "\$*" in
      *paper-search*) echo '[{"name":"paper-search","fields":[{"name":"ieee_api_key","value":"FAKE-IEEE-KEY"},{"name":"unpaywall_email","value":"fake@example.invalid"}]}]' ;;
      *) echo '[]' ;;
    esac ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "$STUB/bw"
}

# apply_with PATHPREFIX: apply (no scripts) with stderr captured in \$output.
apply_with() {
  HOME="$SB_HOME" USERPROFILE="$SB_HOME" XDG_CONFIG_HOME="$SB_HOME/.config" \
    PATH="$1:$PATH" run chezmoi_iso apply --exclude scripts --destination "$SB_DEST"
}
# a PATH without bw: a dir holding only the tools chezmoi's apply needs is not
# required; the stub dir is simply empty and the host has no bw on PATH.
nobw() { command -v bw >/dev/null 2>&1 && skip "host has bw on PATH"; mkdir -p "$SB/empty"; }

@test "unlocked vault renders paper-search env with both keys" {
  stub_bw unlocked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ -f "$SB_DEST/$ENVFILE" ]
  grep -qx 'PAPER_SEARCH_MCP_IEEE_API_KEY=FAKE-IEEE-KEY' "$SB_DEST/$ENVFILE"
  grep -qx 'PAPER_SEARCH_MCP_UNPAYWALL_EMAIL=fake@example.invalid' "$SB_DEST/$ENVFILE"
  [ "$(stat -c %a "$SB_DEST/$ENVFILE")" = 600 ]
}

@test "locked vault: file absent and one warning" {
  stub_bw locked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/$ENVFILE" ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 1 ]
  [[ "$output" == *"paper-search-mcp/.env"* ]]
}

@test "bw missing: file absent and one warning" {
  nobw
  apply_with "$SB/empty"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/$ENVFILE" ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 1 ]
}

@test "apply exits 0 when locked" {
  stub_bw unauthenticated
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ -f "$SB_DEST/.tmux.conf" ]
}

@test "unlocked vault but item missing: file absent, exits 0" {
  stub_bw unlocked
  sed -i 's/paper-search/other-item/' "$STUB/bw"
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/$ENVFILE" ]
}

@test "locked re-apply leaves an existing secret file byte-identical, one warning" {
  stub_bw unlocked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  before="$(sha256sum "$SB_DEST/$ENVFILE")"
  stub_bw locked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$SB_DEST/$ENVFILE")" = "$before" ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 1 ]
}

@test "bw that exits non-zero counts as locked: warning, exit 0" {
  printf '#!/bin/sh\nexit 1\n' > "$STUB/bw"; chmod +x "$STUB/bw"
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/$ENVFILE" ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 1 ]
}

@test "unlocked but field missing: existing file untouched, one warning" {
  stub_bw unlocked
  apply_with "$STUB"
  before="$(sha256sum "$SB_DEST/$ENVFILE")"
  sed -i 's/unpaywall_email/other_field/' "$STUB/bw"
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$SB_DEST/$ENVFILE")" = "$before" ]
  [ "$(grep -c 'not found' <<<"$output")" -eq 1 ]
}

@test "no secret values are committed in the repo" {
  ! git -C "$REPO_ROOT" grep -qE 'FAKE-IEEE-KEY|BW_SESSION=[A-Za-z0-9+/=]{20,}' -- home lib doctor.d
}
