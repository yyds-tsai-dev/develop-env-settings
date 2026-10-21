# Codex checks (install, MCP servers in config.toml, skills, login).
# Protocol: see bin/doctor. --ci: login is SKIP. Server role only (Codex is
# installed by 55-codex on Servers), so every check SKIPs on a plain Desktop.

_codex_manifest() { echo "$DOCTOR_ROOT/home/.chezmoidata/manifest.yaml"; }

_codex_present() {
  command -v codex >/dev/null 2>&1 && return 0
  echo "codex not on PATH: $DOCTOR_FIX"; return 1
}

# _codex_mcp_names: config names (lock key minus "mcp-") of the manifest MCP
# servers whose clients include codex.
_codex_mcp_names() {
  awk '/^[a-z_]+:/ { s = ($1 == "mcp:") }
       s && /^  - name:/ { n = $3; sub(/^mcp-/, "", n) }
       s && /^    clients:/ && /codex/ { print n }' "$(_codex_manifest)"
}

# _codex_bundles: names of the manifest's codex.skill_bundles.
_codex_bundles() {
  awk '/^codex:/ { c = 1; next } /^[a-z_]+:/ { c = 0 }
       c && /^  skill_bundles:/ { s = 1; next } c && /^  [a-z_]+:/ { s = 0 }
       c && s && match($0, /^    - \{ name: *[^,} ]+/) { v = substr($0, RSTART, RLENGTH); sub(/.*name: */, "", v); print v }' "$(_codex_manifest)"
}

# _codex_bundle_plugins: "<name>|<claude_plugin>|<plugin_json>" per bundle that has both.
_codex_bundle_plugins() {
  awk '/^codex:/ { c = 1; next } /^[a-z_]+:/ { c = 0 }
       c && /^    - \{ name:/ && /claude_plugin:/ && /plugin_json:/ {
         n = $0; sub(/.*name: */, "", n); sub(/[,} ].*/, "", n)
         p = $0; sub(/.*claude_plugin: *"?/, "", p); sub(/["},].*/, "", p)
         j = $0; sub(/.*plugin_json: *"?/, "", j); sub(/["}, ].*/, "", j)
         print n "|" p "|" j }' "$(_codex_manifest)"
}

# _codex_skill_dirs: claude.skills dirs that are also fetched for codex.
_codex_skill_dirs() {
  awk '/^  skills:/ { s = 1; next } /^[a-z_]+:/ || /^  [a-z_]+:/ { s = 0 }
       s && /codex: true/ && match($0, /dir: *[^,} ]+/) { v = substr($0, RSTART, RLENGTH); sub(/dir: */, "", v); print v }' "$(_codex_manifest)"
}

check_codex_installed() {
  doctor_server_only || return
  _codex_present || return 1
  codex --version >/dev/null 2>&1 && return 0
  echo "codex --version failed"; return 1
}
register check_codex_installed

# Every manifest server is a [mcp_servers.<name>] table in ~/.codex/config.toml
# and sets tool_timeout_sec.
check_codex_mcp() {
  doctor_server_only || return
  local cfg="$HOME/.codex/config.toml" n missing= notimeout= have
  [ -f "$cfg" ] || { echo "$cfg missing: $DOCTOR_FIX"; return 1; }
  have="$(awk '/^\[mcp_servers\.[^.]+\]$/ { n = $0; sub(/^\[mcp_servers\./, "", n); sub(/\]$/, "", n); print n " table"; next }
               /^\[/ { if ($0 !~ /^\[mcp_servers\./) n = ""; next }
               n && /^tool_timeout_sec *=/ { print n " timeout" }' "$cfg")"
  for n in $(_codex_mcp_names); do
    if ! printf '%s\n' "$have" | grep -qx "$n table"; then missing="$missing $n"
    elif ! printf '%s\n' "$have" | grep -qx "$n timeout"; then notimeout="$notimeout $n"
    fi
  done
  [ -z "$missing$notimeout" ] && return 0
  [ -n "$missing" ] && echo "MCP server(s) missing from config.toml:$missing"
  [ -n "$notimeout" ] && echo "MCP server(s) with no tool_timeout_sec:$notimeout"
  return 1
}
register check_codex_mcp

# Every manifest bundle installed (recorded by the install script), every
# recorded skill resolves to a SKILL.md, links are relative.
check_codex_skills() {
  doctor_server_only || return
  local sk="$HOME/.codex/skills" st="$HOME/.codex/skill-bundles/.devenv-skills"
  local b d kind name missing= broken= abs=
  [ -f "$st" ] || { echo "$st missing: $DOCTOR_FIX"; return 1; }
  for b in $(_codex_bundles); do grep -q "^bundle $b " "$st" || missing="$missing $b"; done
  for d in codex-queue-workflow codebase-memory $(_codex_skill_dirs); do
    grep -qx "skill $d" "$st" || [ "$d" = codex-queue-workflow ] || missing="$missing $d"
  done
  [ -f "$sk/codex-queue-workflow/SKILL.md" ] || missing="$missing codex-queue-workflow"
  while read -r kind name; do
    [ "$kind" = skill ] || continue
    [ -f "$sk/$name/SKILL.md" ] || { broken="$broken $name"; continue; }
    if [ -L "$sk/$name" ]; then
      case "$(readlink "$sk/$name")" in /*) abs="$abs $name" ;; esac
    fi
  done < "$st"
  [ -z "$missing$broken$abs" ] && return 0
  [ -n "$missing" ] && echo "not installed:$missing"
  [ -n "$broken" ] && echo "skill(s) not resolving to a SKILL.md:$broken"
  [ -n "$abs" ] && echo "absolute link:$abs"
  echo "$DOCTOR_FIX"
  return 1
}
register check_codex_skills

# WARN (never FAIL) when a bundle's plugin.json version (its 12-char SHA when the
# file has none) differs from the version of Claude's installed plugin for the
# same upstream: the two clients have drifted apart.
check_codex_bundle_versions() {
  doctor_server_only || return
  local st="$HOME/.codex/skill-bundles/.devenv-skills" reg="$HOME/.claude/plugins/installed_plugins.json"
  local name plugin pj dir cv clv drift=
  [ -f "$st" ] || { echo "no $st yet"; return 2; }
  [ -f "$reg" ] || { echo "no Claude plugins installed"; return 2; }
  while IFS='|' read -r name plugin pj; do
    dir="$(sed -n "s/^bundle $name //p" "$st")"
    [ -n "$dir" ] || continue
    cv="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$HOME/.codex/skill-bundles/$dir/$pj" 2>/dev/null | head -n 1)"
    [ -n "$cv" ] || cv="${dir##*-}"
    clv="$(awk -v id="\"$plugin\": [" 'index($0, id) { f = 1; next }
             f && /"version":/ { sub(/.*"version": *"/, ""); sub(/".*/, ""); print; exit }' "$reg")"
    [ -n "$clv" ] || continue
    [ "$cv" = "$clv" ] || drift="$drift $name(codex $cv, claude $clv)"
  done <<DEVENV_BUNDLES
$(_codex_bundle_plugins)
DEVENV_BUNDLES
  [ -z "$drift" ] && return 0
  echo "Codex bundle and Claude plugin versions differ:$drift (run bin/update; claude plugin update <plugin>)"
  return 3
}
register check_codex_bundle_versions

check_codex_login() {
  doctor_server_only || return
  if [ "${DOCTOR_CI:-0}" = 1 ]; then echo "login check skipped in --ci"; return 2; fi
  _codex_present || return 1
  codex login status >/dev/null 2>&1 && return 0
  echo "not logged in: run codex login"; return 1
}
register check_codex_login
