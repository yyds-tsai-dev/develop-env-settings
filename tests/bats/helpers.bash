# Shared bats helpers. Everything runs against isolated temp dirs; the real
# $HOME is never read or written.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME:-$(dirname "${BASH_SOURCE[0]}")}/../.." && pwd)"
CHEZMOI="$REPO_ROOT/.tools/bin/chezmoi"
[ -x "$CHEZMOI" ] || CHEZMOI="$REPO_ROOT/.tools/bin/chezmoi.exe"

# new_sandbox: create a temp dir tree and export SB, SB_HOME, SB_CONFIG,
# SB_CACHE, SB_STATE, SB_DEST. HOME is redirected into the sandbox.
new_sandbox() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/devenv-sb.XXXXXX")"
  SB_HOME="$SB/home"; SB_CONFIG="$SB/chezmoi.toml"; SB_CACHE="$SB/cache"
  SB_STATE="$SB/state.boltdb"; SB_DEST="$SB/dest"
  mkdir -p "$SB_HOME" "$SB_CACHE" "$SB_DEST"
  export SB SB_HOME SB_CONFIG SB_CACHE SB_STATE SB_DEST
}

# chezmoi_iso ARGS...: run chezmoi fully isolated.
chezmoi_iso() {
  HOME="$SB_HOME" USERPROFILE="$SB_HOME" XDG_CONFIG_HOME="$SB_HOME/.config" \
    "$CHEZMOI" --config "$SB_CONFIG" --cache "$SB_CACHE" \
    --persistent-state "$SB_STATE" --source "$REPO_ROOT" "$@"
}

# init_role ROLE: write the isolated config via `chezmoi init`.
# chezmoi derives .chezmoi.os from the host, so tests skip on non-matching hosts.
init_role() {
  local role="$1"
  chezmoi_iso init --promptChoice "role=$role" --no-tty </dev/null
}

# render_home ROLE: apply (no scripts) into a temp destination and echo it.
render_home() {
  local role="$1"
  new_sandbox
  init_role "$role" >&2 || return 1
  chezmoi_iso apply --exclude scripts --destination "$SB_DEST" >&2 || return 1
  echo "$SB_DEST"
}
