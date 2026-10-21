# Linux Server tool layer checks (micromamba envs, links, Node, uv tools).
# Protocol: see bin/doctor.

_tools_linux() {
  [ "$(uname -s)" = Linux ] && return 0
  echo "linux server tool layer only"; return 2
}

_tools_manifest() { echo "$DOCTOR_ROOT/home/.chezmoidata/manifest.yaml"; }

check_micromamba_envs() {
  doctor_server_only || return
  _tools_linux || return
  local e missing=
  [ -x "$HOME/.local/bin/micromamba" ] || { echo "~/.local/bin/micromamba missing"; return 1; }
  for e in cli-tools pdftools; do
    [ -d "$HOME/micromamba/envs/$e/conda-meta" ] || missing="$missing $e"
  done
  [ -z "$missing" ] && return 0
  echo "missing micromamba env(s):$missing: $DOCTOR_FIX"; return 1
}
register check_micromamba_envs

check_cli_tools_linked() {
  doctor_server_only || return
  _tools_linux || return
  local b missing=
  for b in fzf fd bat rg jq gh git-lfs pdftotext; do
    [ -x "$HOME/.local/bin/$b" ] || missing="$missing $b"
  done
  [ -z "$missing" ] && return 0
  echo "not in ~/.local/bin:$missing: $DOCTOR_FORCE"; return 1
}
register check_cli_tools_linked

check_node_default() {
  doctor_server_only || return
  _tools_linux || return
  local fnm major v
  fnm="$(command -v fnm 2>/dev/null || echo "$HOME/.local/bin/fnm")"
  [ -x "$fnm" ] || { echo "fnm not found"; return 1; }
  major="$(sed -n 's/^node: *{ *major: *\([0-9][0-9]*\).*/\1/p' "$(_tools_manifest)")"
  v="$("$fnm" exec --using=default -- node --version 2>/dev/null)" \
    || { echo "fnm has no default Node"; return 1; }
  v="${v#v}"
  [ "${v%%.*}" = "$major" ] && return 0
  echo "default Node is $v, manifest wants $major"; return 1
}
register check_node_default

check_uv_tools() {
  doctor_server_only || return
  _tools_linux || return
  local uv list t missing=
  uv="$(command -v uv 2>/dev/null || echo "$HOME/.local/bin/uv")"
  [ -x "$uv" ] || { echo "uv not found"; return 1; }
  list="$("$uv" tool list 2>/dev/null)"
  for t in $(awk '/^[A-Za-z_]+:/ { s = ($1 == "uv_tools:") }
                  s && match($0, /name: *[^,} ]+/) { v = substr($0, RSTART, RLENGTH); sub(/name: */, "", v); print v }' \
             "$(_tools_manifest)"); do
    printf '%s\n' "$list" | grep -q "^$t v" || missing="$missing $t"
  done
  [ -z "$missing" ] && return 0
  echo "uv tool(s) not installed:$missing: $DOCTOR_FIX"; return 1
}
register check_uv_tools
