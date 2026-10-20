#!/usr/bin/env bats
# bats file_tags=codex
#
# Codex: AGENTS.md, generic agents, the vendored codex-queue-workflow skill, the
# managed config.toml merge (modify_ script), the install script (standalone
# build, codebase-memory-mcp skill and agents, skill bundles) and its doctor
# checks. Host tests render into sandboxes under /tmp with stub `codex`, `curl`
# and `codebase-memory-mcp`; the real $HOME is never read or written and no
# real `codex` command runs on the host. The container test is in bootstrap.bats.

bats_require_minimum_version 1.5.0
load helpers

SCRIPT=run_onchange_after_55-codex.sh.tmpl
MODIFY=home/private_dot_codex/modify_private_config.toml.tmpl

setup() {
  [ "$(uname -s)" = Linux ] || skip "server role renders on linux"
  new_sandbox
  STUB="$SB/stub"; mkdir -p "$STUB"
}
teardown() { rm -rf "$SB"; }

lock() { sed -n "s/^  $1: *'\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$REPO_ROOT/home/.chezmoidata/versions.yaml"; }

# codex_mcp_names: config names (lock key minus "mcp-") of manifest servers for codex.
codex_mcp_names() {
  awk '/^[a-z_]+:/ { s = ($1 == "mcp:") }
       s && /^  - name:/ { n = $3; sub(/^mcp-/, "", n) }
       s && /^    clients:/ && /codex/ { print n }' "$REPO_ROOT/home/.chezmoidata/manifest.yaml"
}

# tool_timeouts FILE: "<server> <tool_timeout_sec or MISSING>" per [mcp_servers.<server>].
tool_timeouts() {
  awk '/^\[mcp_servers\.[^.]+\]$/ { if (n) print n, (t ? t : "MISSING"); n = $0; sub(/^\[mcp_servers\./, "", n); sub(/\]$/, "", n); t = ""; next }
       /^\[/ && !/^\[mcp_servers\./ { if (n) print n, (t ? t : "MISSING"); n = "" }
       n && /^tool_timeout_sec *=/ { t = $3 }
       END { if (n) print n, (t ? t : "MISSING") }' "$1"
}

render_tmpl() {  # render_tmpl SRC OUT
  init_role server >&2
  chezmoi_iso execute-template < "$REPO_ROOT/$1" > "$2"
}

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

@test "AGENTS.md, generic agents and the vendored skill render without project nouns or home paths" {
  run render_home server
  [ "$status" -eq 0 ]
  dest="${lines[${#lines[@]}-1]}"
  c="$dest/.codex"
  for f in AGENTS.md agents/deep-reasoner.toml agents/fast-worker.toml \
           skills/codex-queue-workflow/SKILL.md skills/codex-queue-workflow/scripts/completion_notify.py; do
    [ -s "$c/$f" ] || { echo "$f missing"; false; }
  done
  run grep -rniE 'DREAMPlace|placer|hMETIS|evaluator_gpu|env\.sh|IO-Aware|ioplace|H100' \
    "$c/AGENTS.md" "$c/agents" "$c/skills/codex-queue-workflow"
  [ "$status" -eq 1 ]
  run grep -rnE '/ldaphome|/home/[a-z]|/Users/' "$c"
  [ "$status" -eq 1 ]
  [ "$(stat -c %a "$c")" = 700 ]
  # the three managed blocks survive verbatim
  for b in caveman-default codebase-memory-mcp codex-efficient-waiting; do
    grep -qF "<!-- $b:start -->" "$c/AGENTS.md" && grep -qF "<!-- $b:end -->" "$c/AGENTS.md"
  done
  grep -qF '`~/.codex/skills/caveman/SKILL.md`' "$c/AGENTS.md"
  grep -qF '`~/.codex/skills/codex-queue-workflow/SKILL.md`' "$c/AGENTS.md"
  # roles keep their models and efforts
  grep -qx 'model = "gpt-6-astra"' "$c/agents/deep-reasoner.toml"
  grep -qx 'model_reasoning_effort = "high"' "$c/agents/deep-reasoner.toml"
  grep -qx 'sandbox_mode = "read-only"' "$c/agents/deep-reasoner.toml"
  grep -qx 'model = "gpt-5.6-terra"' "$c/agents/fast-worker.toml"
  grep -qx 'model_reasoning_effort = "low"' "$c/agents/fast-worker.toml"
  [ -z "$(find "$c" -name __pycache__)" ]
}

@test "config.toml: every manifest server at its locked version, bare, with tool_timeout_sec" {
  command -v uv >/dev/null 2>&1 || skip "uv needed for the merge"
  run render_home server
  [ "$status" -eq 0 ]
  dest="${lines[${#lines[@]}-1]}"
  f="$dest/.codex/config.toml"
  [ -s "$f" ]
  [ "$(stat -c %a "$f")" = 600 ]
  grep -qx 'model = "gpt-6-astra"' "$f"
  grep -qx 'model_reasoning_effort = "medium"' "$f"
  grep -qx 'approvals_reviewer = "user"' "$f"
  grep -qx 'model_context_window = 1000000' "$f"
  grep -qx 'model_auto_compact_token_limit = 400000' "$f"
  grep -qF 'status_line = ["model-with-reasoning",' "$f"
  n=0
  for s in $(codex_mcp_names); do
    grep -qx "\[mcp_servers.$s\]" "$f" || { echo "server $s missing"; false; }
    n=$((n + 1))
  done
  [ "$n" -eq 5 ]
  run tool_timeouts "$f"
  echo "$output"
  [ "${#lines[@]}" -eq 5 ]
  [[ "$output" != *MISSING* ]]
  grep -qF "\"semble[mcp]==$(lock mcp-semble)\"" "$f"
  grep -qF '"--python","3.12"' "$f"
  grep -qF "\"@next-ai-drawio/mcp-server@$(lock mcp-drawio)\"" "$f"
  grep -qx 'env_vars = \["CBM_CACHE_DIR","CBM_RUNTIME_DIR"\]' "$f"
  grep -qx '\[mcp_servers.codebase-memory-mcp.tools.index_status\]' "$f"
  [ "$(grep -c '^command = "codebase-memory-mcp hook-augment"$' "$f")" -eq 2 ]
  ! grep -qE '^command = "/' "$f"
}

@test "modify script merges into the current file and is idempotent" {
  command -v uv >/dev/null 2>&1 || skip "uv needed for the merge"
  render_tmpl "$MODIFY" "$SB/modify.sh"
  sh -n "$SB/modify.sh"
  printf '%s\n' 'service_tier = "default"' '' '[projects."/x/repo"]' 'trust_level = "trusted"' '' \
    '[mcp_servers.old]' 'command = "/x/old"' '' '[hooks.state."/x/config.toml:session_start:0:0"]' \
    'trusted_hash = "sha256:00"' > "$SB/cur.toml"
  HOME="$SB_HOME" sh "$SB/modify.sh" < "$SB/cur.toml" > "$SB/once.toml"
  grep -qx 'trust_level = "trusted"' "$SB/once.toml"
  grep -qx 'trusted_hash = "sha256:00"' "$SB/once.toml"
  grep -qx 'service_tier = "default"' "$SB/once.toml"
  ! grep -q 'mcp_servers.old' "$SB/once.toml"
  grep -qx '\[mcp_servers.semble\]' "$SB/once.toml"
  HOME="$SB_HOME" sh "$SB/modify.sh" < "$SB/once.toml" > "$SB/twice.toml"
  cmp "$SB/once.toml" "$SB/twice.toml"
}

@test "modify script without uv warns and re-emits the current file unchanged" {
  render_tmpl "$MODIFY" "$SB/modify.sh"
  printf '# mine\nservice_tier = "default"\n[projects."/x"]\ntrust_level = "trusted"\n' > "$SB/cur.toml"
  for c in sh cat mktemp rm; do ln -s "$(command -v $c)" "$STUB/$c"; done
  HOME="$SB_HOME" PATH="$STUB" run --separate-stderr sh "$SB/modify.sh" < "$SB/cur.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$SB/cur.toml")" ]
  [[ "$stderr" == *"warning: uv missing"* ]]
  # a failing merge also keeps the file
  stub uv 'exit 3'
  HOME="$SB_HOME" PATH="$STUB" run --separate-stderr sh "$SB/modify.sh" < "$SB/cur.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$SB/cur.toml")" ]
  [[ "$stderr" == *"warning: merging the managed Codex config failed"* ]]
}

# fake_world SCRIPT: stubs for codex, codebase-memory-mcp and curl. curl logs every
# URL to $SB/curl.log; a codeload URL returns a tarball of a fake repo holding
# exactly the skill paths the rendered SCRIPT's `bundle` lines name (skills_dir
# bundles get two skills and one non-skill dir); install.sh records its env.
fake_world() {
  local f="$1"
  mkdir -p "$SB/repos"
  bundle() {
    local r="$SB/repos/${3%%/*}_${3#*/}" sdir="$5" json="$6"; shift 6
    mkdir -p "$r"
    if [ -n "$sdir" ]; then
      for s in alpha beta; do mkdir -p "$r/$sdir/$s"; echo "$s" > "$r/$sdir/$s/SKILL.md"; done
      mkdir -p "$r/$sdir/not-a-skill"; echo x > "$r/$sdir/not-a-skill/README.md"
    fi
    if [ -n "$json" ]; then   # a plugin.json listing three skills, plus one unlisted
      mkdir -p "$r/${json%/*}"
      printf '{\n  "name": "x",\n  "version": "9.9.9",\n  "keywords": [\n    "tdd"\n  ],\n  "skills": [\n    "./skills/eng/tdd",\n    "./skills/eng/to-spec",\n    "./skills/prod/grilling"\n  ]\n}\n' > "$r/$json"
      for p in skills/eng/tdd skills/eng/to-spec skills/prod/grilling skills/eng/unlisted; do mkdir -p "$r/$p"; echo "$p" > "$r/$p/SKILL.md"; done
    fi
    for p in "$@"; do mkdir -p "$r/$p"; echo "$p" > "$r/$p/SKILL.md"; done
  }
  eval "$(grep '^bundle ' "$f")"
  unset -f bundle
  cat > "$STUB/curl" <<EOF
#!/bin/sh
while [ \$# -gt 1 ]; do [ "\$1" = -o ] && { out="\$2"; url="\$3"; break; }; shift; done
echo "\$url" >> "$SB/curl.log"
case "\$url" in
  https://codeload.github.com/*)
    rest="\${url#https://codeload.github.com/}"; repo="\${rest%%/tar.gz/*}"
    d="$SB/repos/\$(echo "\$repo" | tr / _)"; [ -d "\$d" ] || exit 22
    tar -czf "\$out" -C "$SB/repos" --transform "s,^\${d##*/},top," "\${d##*/}" ;;
  */scripts/install/install.sh)
    printf '#!/bin/sh\necho "release=\$CODEX_RELEASE ni=\$CODEX_NON_INTERACTIVE" >> "$SB/codex-install.log"\n' > "\$out" ;;
  *) echo "skill from \$url" > "\$out" ;;
esac
EOF
  chmod +x "$STUB/curl"
  stub codex "[ \"\$1\" = --version ] && echo 'codex-cli $(lock codex)'"
  cat > "$STUB/codebase-memory-mcp" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "codebase-memory-mcp $(lock codebase-memory-mcp)" ;;
  install)
    echo "\$HOME" >> "$SB/cbm-install.log"
    mkdir -p "\$HOME/.codex/skills/codebase-memory" "\$HOME/.codex/agents"
    echo cbm > "\$HOME/.codex/skills/codebase-memory/SKILL.md"
    for a in codebase-memory codebase-memory-scout codebase-memory-auditor; do echo "\$a" > "\$HOME/.codex/agents/\$a.toml"; done
    echo 'mcp = "/abs"' > "\$HOME/.codex/config.toml"; echo block > "\$HOME/.codex/AGENTS.md" ;;
esac
EOF
  chmod +x "$STUB/codebase-memory-mcp"
}

run_script() { HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" run sh "$1"; }

@test "install script links every bundle skill with relative symlinks and is idempotent" {
  render_tmpl "home/.chezmoiscripts/$SCRIPT" "$SB/codex.sh"
  sh -n "$SB/codex.sh"
  fake_world "$SB/codex.sh"
  # a plain dir from an earlier skill-installer run and an absolute-path link
  mkdir -p "$SB_HOME/.codex/skills/caveman" "$SB_HOME/.codex/skills/.system/x"
  echo old > "$SB_HOME/.codex/skills/caveman/SKILL.md"
  ln -s /nonexistent/brainstorming "$SB_HOME/.codex/skills/alpha"
  run_script "$SB/codex.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *warning* ]]
  sk="$SB_HOME/.codex/skills"
  st="$SB_HOME/.codex/skill-bundles/.devenv-skills"
  [ -s "$st" ]
  for b in $(sed -n 's/^bundle \x27\([^\x27]*\)\x27.*/\1/p' "$SB/codex.sh"); do
    grep -q "^bundle $b [a-z]" "$st" || { echo "bundle $b not recorded"; false; }
  done
  n=0
  while read -r kind name; do
    [ "$kind" = skill ] || continue
    [ -f "$sk/$name/SKILL.md" ] || { echo "skill $name does not resolve"; false; }
    if [ -L "$sk/$name" ]; then
      case "$(readlink "$sk/$name")" in ../skill-bundles/*) ;; *) echo "$name: $(readlink "$sk/$name")"; false ;; esac
    fi
    n=$((n + 1))
  done < "$st"
  [ "$n" -ge 14 ]
  [ ! -e "$sk/unlisted" ]
  [ ! -e "$sk/not-a-skill" ]
  [ "$(readlink "$sk/caveman")" = "../skill-bundles/caveman-$(lock codex-bundle-caveman)/skills/caveman" ]
  [ "$(readlink "$sk/tdd")" = "../skill-bundles/mattpocock-skills-$(lock codex-bundle-mattpocock-skills)/skills/eng/tdd" ]
  [ "$(readlink "$sk/grilling")" = "../skill-bundles/mattpocock-skills-$(lock codex-bundle-mattpocock-skills)/skills/prod/grilling" ]
  # github-head bundles fetch the locked 12-char SHA
  grep -qx "https://codeload.github.com/jgraph/drawio-mcp/tar.gz/$(lock codex-bundle-drawio)" "$SB/curl.log"
  [ "$(lock codex-bundle-drawio | wc -c)" -eq 13 ]
  [ "$(readlink "$sk/academic-paper")" = "../skill-bundles/academic-research-skills-$(lock codex-bundle-academic-research-skills)/academic-paper" ]
  [ "$(readlink "$sk/alpha")" = "../skill-bundles/drawio-$(lock codex-bundle-drawio)/plugins/codex/drawio/skills/alpha" ] \
    || [ "$(readlink "$sk/alpha")" = "../skill-bundles/superpowers-$(lock codex-bundle-superpowers)/skills/alpha" ]
  ls "$SB_HOME/.codex/skill-bundles/.replaced/" | grep -q '^caveman\.'   # moved aside, not deleted
  [ -d "$sk/.system/x" ]
  # superpowers resolves through the lock and its v-tag
  grep -qF "https://codeload.github.com/obra/superpowers/tar.gz/v$(lock codex-bundle-superpowers)" "$SB/curl.log"
  # find-skills / paper-search: Claude's urls and locks
  grep -q "vercel-labs/skills/v$(lock skill-find-skills)/" "$sk/find-skills/SKILL.md"
  grep -q "openags/paper-search-mcp/v$(lock paper-search-mcp)/" "$sk/paper-search/SKILL.md"
  # cbm: skill and agents copied from a scratch HOME; managed files untouched
  [ "$(cat "$sk/codebase-memory/SKILL.md")" = cbm ]
  for a in codebase-memory codebase-memory-scout codebase-memory-auditor; do [ -s "$SB_HOME/.codex/agents/$a.toml" ]; done
  [ ! -e "$SB_HOME/.codex/config.toml" ] && [ ! -e "$SB_HOME/.codex/AGENTS.md" ]
  [ "$(grep -c . "$SB/cbm-install.log")" -eq 1 ]
  ! grep -qx "$SB_HOME" "$SB/cbm-install.log"
  [ ! -e "$SB/codex-install.log" ]   # locked codex already installed
  # rerun: no tarball fetched again, cbm installer not rerun, same links
  find "$sk" -maxdepth 1 -type l -exec sh -c 'printf "%s %s\n" "$1" "$(readlink "$1")"' _ {} \; | sort > "$SB/links1"
  : > "$SB/curl.log"
  run_script "$SB/codex.sh"
  [ "$status" -eq 0 ]
  ! grep -q codeload "$SB/curl.log"
  [ "$(grep -c . "$SB/cbm-install.log")" -eq 1 ]
  find "$sk" -maxdepth 1 -type l -exec sh -c 'printf "%s %s\n" "$1" "$(readlink "$1")"' _ {} \; | sort > "$SB/links2"
  cmp "$SB/links1" "$SB/links2"
}

@test "install script installs the locked codex when missing or different" {
  render_tmpl "home/.chezmoiscripts/$SCRIPT" "$SB/codex.sh"
  fake_world "$SB/codex.sh"
  stub codex "[ \"\$1\" = --version ] && echo 'codex-cli 0.0.1'"
  run_script "$SB/codex.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx "release=$(lock codex) ni=1" "$SB/codex-install.log"
  grep -qx "https://raw.githubusercontent.com/openai/codex/rust-v$(lock codex)/scripts/install/install.sh" "$SB/curl.log"
}

@test "install script warns and exits 0 when downloads fail" {
  render_tmpl "home/.chezmoiscripts/$SCRIPT" "$SB/codex.sh"
  fake_world "$SB/codex.sh"
  stub curl 'exit 22'
  rm -f "$STUB/codex"
  run_script "$SB/codex.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: could not download the Codex"* ]]
  [[ "$output" == *"warning: could not fetch obra/superpowers"* ]]
  [ -z "$(ls -A "$SB_HOME/.codex/skill-bundles" | grep -v '^\.devenv-skills$')" ]   # no half-unpacked bundle
  ! grep -q '^bundle ' "$SB_HOME/.codex/skill-bundles/.devenv-skills"
}

@test "doctor codex checks: pass with everything present, login skips in --ci" {
  command -v uv >/dev/null 2>&1 || skip "uv needed for the merge"
  render_tmpl "home/.chezmoiscripts/$SCRIPT" "$SB/codex.sh"
  fake_world "$SB/codex.sh"
  run_script "$SB/codex.sh"
  [ "$status" -eq 0 ]
  mkdir -p "$SB_HOME/.codex/skills/codex-queue-workflow"; : > "$SB_HOME/.codex/skills/codex-queue-workflow/SKILL.md"
  render_tmpl "$MODIFY" "$SB/modify.sh"
  HOME="$SB_HOME" sh "$SB/modify.sh" < /dev/null > "$SB_HOME/.codex/config.toml"
  cat > "$STUB/codex" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "--version "*) echo "codex-cli $(lock codex)" ;;
  "login status") exit 1 ;;
esac
EOF
  chmod +x "$STUB/codex"
  HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [ "$status" -eq 0 ]
  for c in codex_installed codex_mcp codex_skills; do [[ "$output" == *"PASS $c"* ]]; done
  [[ "$output" == *"SKIP codex_login"* ]]
  [[ "$output" == *"SKIP codex_bundle_versions"* ]]   # no Claude plugins
  # Claude plugin versions: same as the bundles -> PASS; one differs -> WARN, exit 0
  mkdir -p "$SB_HOME/.claude/plugins"
  reg() {
    printf '{\n  "version": 2,\n  "plugins": {\n    "mattpocock-skills@claude-plugins-official": [\n      {\n        "scope": "user",\n        "version": "%s"\n      }\n    ],\n    "caveman@caveman": [\n      {\n        "version": "%s"\n      }\n    ]\n  }\n}\n' "$1" "$2" > "$SB_HOME/.claude/plugins/installed_plugins.json"
  }
  reg 9.9.9 "$(lock codex-bundle-caveman)"
  HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS codex_bundle_versions"* ]]
  reg 1.0.0 "$(lock codex-bundle-caveman)"
  HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN codex_bundle_versions: Codex bundle and Claude plugin versions differ: codex-bundle-mattpocock-skills(codex 9.9.9, claude 1.0.0)"* ]]
  [[ "$output" != *caveman\(* ]]
  HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL codex_login"* ]]
  # a server without tool_timeout_sec, a missing server, a broken or absolute link FAIL
  sed -i '/^\[mcp_servers.drawio\]/,/^$/{/tool_timeout_sec/d}' "$SB_HOME/.codex/config.toml"
  sed -i 's/^\[mcp_servers.graphify\]/[mcp_servers.graphify-old]/' "$SB_HOME/.codex/config.toml"
  rm "$SB_HOME/.codex/skills/tdd"; ln -s "$SB_HOME/.codex/skill-bundles/x" "$SB_HOME/.codex/skills/tdd"
  rm "$SB_HOME/.codex/skills/caveman"; ln -s "$SB/elsewhere/caveman" "$SB_HOME/.codex/skills/caveman"
  mkdir -p "$SB/elsewhere/caveman"; : > "$SB/elsewhere/caveman/SKILL.md"
  HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL codex_mcp"*"graphify"* ]]
  [[ "$output" == *"no tool_timeout_sec: drawio"* ]]
  [[ "$output" == *"FAIL codex_skills"*"tdd"* ]]
  [[ "$output" == *"absolute link: caveman"* ]]
  # a bundle that never installed FAILs
  sed -i '/^bundle codex-bundle-adhd /d' "$SB_HOME/.codex/skill-bundles/.devenv-skills"
  HOME="$SB_HOME" PATH="$STUB:$PATH" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"codex-bundle-adhd"* ]]
  # no codex at all
  rm "$STUB/codex"
  HOME="$SB_HOME" PATH="$STUB:/usr/bin:/bin" DOCTOR_ONLY='65-*' run "$REPO_ROOT/bin/doctor" --ci
  [[ "$output" == *"FAIL codex_installed"* ]]
}

@test "modify script keeps the current file when the post-merge check trips" {
  command -v uv >/dev/null 2>&1 || skip "uv needed for the merge"
  render_tmpl "$MODIFY" "$SB/modify.sh"
  # collapsing blank lines would change this multi-line string: the check refuses
  printf 'note = """a\n\n\n\nb"""\nservice_tier = "default"\n' > "$SB/cur.toml"
  HOME="$SB_HOME" run --separate-stderr sh "$SB/modify.sh" < "$SB/cur.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$SB/cur.toml")" ]
  [[ "$stderr" == *"merged config lost or changed: note"* ]]
  [[ "$stderr" == *"warning: merging the managed Codex config failed"* ]]
}
