#!/usr/bin/env bats
# Bitwarden-backed Secrets. A stub `bw` on PATH answers `status`, `list folders`
# and `list items`; all values are fake. Sandboxes live under /tmp only.

load helpers

ENVFILE=".config/paper-search-mcp/.env"
ZOTFILE=".config/zotero-mcp/config.json"
# skipped TARGET: the number of "Bitwarden locked or missing" warnings for TARGET in $output.
skipped() { grep -c "Bitwarden locked or missing: skipping $1\$" <<<"$output"; }

setup() {
  new_sandbox
  STUB="$SB/stub"; mkdir -p "$STUB"
  # The repo-content check runs everywhere; the rest render the server role,
  # which is Linux-only (desktop-role Secret coverage comes with Task 10).
  [[ "$BATS_TEST_DESCRIPTION" == "no secret values are committed in the repo" ]] && return 0
  [ "$(uname -s)" = Linux ] || skip "server-role Secret tests need a linux host (this host: $(uname -s))"
  init_role server >&2
}
teardown() { chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"; }

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
      *zotero*) echo '[{"name":"zotero","fields":[{"name":"api_key","value":"FAKE-ZOTERO-KEY"},{"name":"library_id","value":"1234567"}]}]' ;;
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
  [ "$(stat -c %a "$SB_DEST/$ENVFILE" 2>/dev/null || stat -f %Lp "$SB_DEST/$ENVFILE")" = 600 ]
}

@test "locked vault: file absent and one warning" {
  stub_bw locked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/$ENVFILE" ]
  [ "$(skipped "$ENVFILE")" -eq 1 ] && [ "$(skipped "$ZOTFILE")" -eq 1 ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 2 ]
  [[ "$output" == *"paper-search-mcp/.env"* ]]
}

@test "bw missing: file absent and one warning" {
  nobw
  apply_with "$SB/empty"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/$ENVFILE" ]
  [ "$(skipped "$ENVFILE")" -eq 1 ] && [ "$(skipped "$ZOTFILE")" -eq 1 ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 2 ]
}

@test "apply exits 0 when locked" {
  stub_bw unauthenticated
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ -f "$SB_DEST/.tmux.conf" ]
}

@test "unlocked vault but item missing: file absent, exits 0" {
  stub_bw unlocked
  sed 's/paper-search/other-item/' "$STUB/bw" > "$SB/bw.new" && cat "$SB/bw.new" > "$STUB/bw"
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
  [ "$(skipped "$ENVFILE")" -eq 1 ] && [ "$(skipped "$ZOTFILE")" -eq 1 ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 2 ]
}

@test "bw that exits non-zero counts as locked: warning, exit 0" {
  printf '#!/bin/sh\nexit 1\n' > "$STUB/bw"; chmod +x "$STUB/bw"
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ ! -e "$SB_DEST/$ENVFILE" ]
  [ "$(skipped "$ENVFILE")" -eq 1 ] && [ "$(skipped "$ZOTFILE")" -eq 1 ]
  [ "$(grep -c 'Bitwarden locked or missing' <<<"$output")" -eq 2 ]
}

@test "unlocked but field missing: existing file untouched, one warning" {
  stub_bw unlocked
  apply_with "$STUB"
  before="$(sha256sum "$SB_DEST/$ENVFILE")"
  sed 's/unpaywall_email/other_field/' "$STUB/bw" > "$SB/bw.new" && cat "$SB/bw.new" > "$STUB/bw"
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$SB_DEST/$ENVFILE")" = "$before" ]
  [ "$(grep -c 'not found' <<<"$output")" -eq 1 ]
}

@test "unlocked vault renders the zotero config (mode 600, dir 700) from the zotero item" {
  stub_bw unlocked
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  f="$SB_DEST/$ZOTFILE"
  [ -f "$f" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["client_env"]; assert d == {"ZOTERO_LOCAL": "false", "ZOTERO_NO_CLAUDE": "true", "ZOTERO_API_KEY": "FAKE-ZOTERO-KEY", "ZOTERO_LIBRARY_ID": "1234567", "ZOTERO_LIBRARY_TYPE": "user"}, d' "$f"
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ]
  [ "$(stat -c %a "${f%/*}" 2>/dev/null || stat -f %Lp "${f%/*}")" = 700 ]
  # a missing library_id skips it, leaving the existing file untouched
  before="$(sha256sum "$f")"
  sed 's/library_id/other_field/' "$STUB/bw" > "$SB/bw.new" && cat "$SB/bw.new" > "$STUB/bw"
  apply_with "$STUB"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$f")" = "$before" ]
  [[ "$output" == *"Bitwarden item zotero field library_id not found: skipping $ZOTFILE"* ]]
}

@test "no secret values are committed in the repo" {
  ! git -C "$REPO_ROOT" grep -qE 'FAKE-IEEE-KEY|FAKE-ZOTERO-KEY|BW_SESSION=[A-Za-z0-9+/=]{20,}' -- home lib doctor.d
}
