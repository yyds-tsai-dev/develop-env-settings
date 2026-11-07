#!/usr/bin/env bats
# bats file_tags=docker
#
# Server Bootstrap end to end, inside Docker (tests/docker/Dockerfile.server).
# The repo working tree (tracked + untracked, minus ignored files) is snapshotted
# into a fresh one-commit git repo and mounted read-only at /repo; every test
# runs `bootstrap.sh --source /repo --role server --ci` in a new container.
# Package caches live in $DEVENV_DOCKER_CACHE (default .tools/docker-cache).

load helpers

BOOT='sh /repo/bootstrap.sh --source /repo --role server --ci'

setup_file() {
  [ "$(uname -s)" = Linux ] || skip "docker server bootstrap runs on linux hosts only (this host: $(uname -s))"
  [ -z "${DEVENV_SKIP_DOCKER:-}" ] || skip "DEVENV_SKIP_DOCKER is set (CI runs this file in its own docker step)"
  command -v docker >/dev/null 2>&1 || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"

  export IMG=devenv-server-test
  docker build -q -t "$IMG" --build-arg UID="$(id -u)" \
    -f "$REPO_ROOT/tests/docker/Dockerfile.server" "$REPO_ROOT/tests/docker" >/dev/null
  export IMG_TMUX=devenv-server-test-tmux
  docker build -q -t "$IMG_TMUX" --build-arg UID="$(id -u)" --build-arg EXTRA_PKGS=tmux \
    -f "$REPO_ROOT/tests/docker/Dockerfile.server" "$REPO_ROOT/tests/docker" >/dev/null

  export WORK; WORK="$(mktemp -d "${TMPDIR:-/tmp}/devenv-docker.XXXXXX")"
  mkdir -p "$WORK/repo"
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z \
    | while IFS= read -r -d '' f; do [ -e "$f" ] || [ -L "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -xf - -C "$WORK/repo"
  git -C "$WORK/repo" init -q -b main
  git -C "$WORK/repo" add -A
  git -C "$WORK/repo" -c user.name=test -c user.email=test@example.invalid \
    commit -q -m snapshot

  export CACHE="${DEVENV_DOCKER_CACHE:-$REPO_ROOT/.tools/docker-cache}"
  mkdir -p "$CACHE/mamba-pkgs" "$CACHE/uv"
}

teardown_file() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; true; }

# in_box [docker-run-option]... SCRIPT: run SCRIPT with bash as user dev
# (image $BOX_IMG, default $IMG).
in_box() {
  local script="${*: -1}" opts=("${@:1:$#-1}")
  docker run --rm \
    -v "$WORK/repo:/repo:ro" \
    -v "$CACHE/mamba-pkgs:/cache/mamba-pkgs" -v "$CACHE/uv:/cache/uv" \
    -e CONDA_PKGS_DIRS=/cache/mamba-pkgs -e UV_CACHE_DIR=/cache/uv \
    ${GITHUB_TOKEN:+-e GITHUB_TOKEN} \
    ${opts[@]+"${opts[@]}"} "${BOX_IMG:-$IMG}" bash -c "$script" 2>&1
}

no_fail_lines() { ! printf '%s\n' "$output" | grep -q '^FAIL '; }

# research add-ons after a server bootstrap (prints one marker line per fact):
# ARIS plugin, its codex MCP server, Claude Scholar, zotero-cli and its skill.
ADDONS='export PATH=$HOME/.local/bin:$PATH
    claude plugin list --json | grep -qF "\"id\": \"aris@aris\"" && echo ARIS-PLUGIN-OK
    claude mcp get codex | grep -qx "  Command: aris-codex-mcp" && echo ARIS-MCP-WRAPPER
    root=$(sed -n "s/^ *\"installPath\": *\"\(.*aris\/aris\/[^\"]*\)\".*/\1/p" ~/.claude/plugins/installed_plugins.json | head -n1)
    [ -f "$root/mcp-servers/codex-exec/server.py" ] && echo ARIS-SERVER-EXISTS
    [ "$(cat ~/.aris/repo)" = "$root" ] && echo ARIS-REPO-OK
    claude mcp list 2>/dev/null | grep "^codex:" | grep -q Connected && echo ARIS-MCP-CONNECTED
    for a in kaggle-miner literature-reviewer paper-miner rebuttal-writer; do [ -s ~/.claude/agents/$a.md ] && echo "SCHOLAR-AGENT $a"; done
    for k in ml-paper-writing zotero-obsidian-bridge defuddle ui-ux-pro-max citation-verification; do [ -s ~/.claude/skills/$k/SKILL.md ] && echo "SCHOLAR-SKILL $k"; done
    for x in skills/planning-with-files skills/daily-coding skills/bug-detective skills/git-workflow skills/verification-loop agents/code-reviewer.md agents/tdd-guide.md; do
      [ -e ~/.claude/$x ] && echo "EXCLUDED-PRESENT $x"; done
    zotero-cli --help >/dev/null 2>&1 && echo ZOTERO-CLI-OK
    for d in .claude/skills/zotero-cli .codex/skills/zotero-cli; do [ -s ~/$d/SKILL.md ] && echo "ZOTERO-SKILL $d"; done
    echo "zotero-blocks=$(grep -c "BEGIN zotero-cli skill" ~/.codex/AGENTS.md)"'

# addons_ok: the ADDONS markers are all in $output.
addons_ok() {
  for m in ARIS-PLUGIN-OK ARIS-MCP-WRAPPER ARIS-SERVER-EXISTS ARIS-REPO-OK ARIS-MCP-CONNECTED ZOTERO-CLI-OK zotero-blocks=1; do
    [[ "$output" == *"$m"* ]] || { echo "missing: $m"; return 1; }
  done
  for a in kaggle-miner literature-reviewer paper-miner rebuttal-writer; do [[ "$output" == *"SCHOLAR-AGENT $a"* ]] || return 1; done
  for k in ml-paper-writing zotero-obsidian-bridge defuddle ui-ux-pro-max citation-verification; do [[ "$output" == *"SCHOLAR-SKILL $k"* ]] || return 1; done
  for d in .claude/skills/zotero-cli .codex/skills/zotero-cli; do [[ "$output" == *"ZOTERO-SKILL $d"* ]] || return 1; done
  [[ "$output" != *EXCLUDED-PRESENT* ]]
}

@test "server bootstrap in container ends with doctor PASS" {
  # Same as the README one-liner: the script arrives on stdin.
  run in_box "cat /repo/bootstrap.sh | sh -s -- --source /repo --role server --ci; rc=\$?
    $ADDONS
    exit \$rc"
  echo "$output"
  [ "$status" -eq 0 ]
  no_fail_lines
  for c in micromamba_envs cli_tools_linked node_default uv_tools fish_present fisher_tide rtk ccusage \
           claude_aris claude_bundles zotero_cli zotero_skills; do
    [[ "$output" == *"PASS $c"* ]]
  done
  addons_ok
}

@test "npx works from a bare non-interactive PATH after bootstrap" {
  run in_box "$BOOT >/tmp/b.log 2>&1 || { cat /tmp/b.log; echo 'bootstrap failed'; exit 1; }
    env -i HOME=\$HOME PATH=\$HOME/.local/bin:/usr/bin:/bin npx --version && echo NPX-OK
    env -i HOME=\$HOME PATH=\$HOME/.local/bin:/usr/bin:/bin node --version
    env -i HOME=\$HOME PATH=\$HOME/.local/bin:/usr/bin:/bin rtk --version
    env -i HOME=\$HOME PATH=\$HOME/.local/bin:/usr/bin:/bin ccusage --version
    env -i HOME=\$HOME PATH=\$HOME/.local/bin:/usr/bin:/bin rtk init --show"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *NPX-OK* ]]
  [[ "$output" == *v24.* ]]
  printf '%s\n' "$output" | grep -qE '^rtk [0-9]+\.[0-9]+'
  printf '%s\n' "$output" | grep -qE '^ccusage [0-9]+\.[0-9]+'
  printf '%s\n' "$output" | grep -q '^\[ok\] Hook: rtk hook claude'
  printf '%s\n' "$output" | grep -q '^\[ok\] Global (~/.claude/CLAUDE.md): @RTK.md reference'
}

@test "second bootstrap changes nothing" {
  run in_box "set -u
    $BOOT >/tmp/1.log 2>&1 || { cat /tmp/1.log; echo 'first bootstrap failed'; exit 1; }
    cm=\$HOME/.local/bin/chezmoi; mm=\$HOME/.local/bin/micromamba
    n1=\$(grep -c PATH ~/.bashrc); e1=\$(\$mm env list); b1=\$(ls -d ~/.dotfiles-backup-* | wc -l)
    sums() { (cd ~ && find .claude/skills .claude/agents .codex/skills/zotero-cli .aris .local/state/develop-env/claude-bundles -type f 2>/dev/null | sort | xargs sha256sum; \$HOME/.local/bin/claude mcp get codex 2>/dev/null | grep -E 'Command|Args'); }
    a1=\$(sums)
    d=\$(\$cm diff --no-pager 2>/dev/null); [ -z \"\$d\" ] || { echo \"diff after first: \$d\"; exit 1; }
    sleep 1
    $BOOT >/tmp/2.log 2>&1 || { cat /tmp/2.log; echo 'second bootstrap failed'; exit 1; }
    d=\$(\$cm diff --no-pager 2>/dev/null); [ -z \"\$d\" ] || { echo \"diff after second: \$d\"; exit 1; }
    [ \"\$(grep -c PATH ~/.bashrc)\" = \"\$n1\" ] || { echo 'PATH line count changed'; exit 1; }
    [ \"\$(\$mm env list)\" = \"\$e1\" ] || { echo 'micromamba env list changed'; exit 1; }
    [ \"\$(ls -d ~/.dotfiles-backup-* | wc -l)\" = \"\$b1\" ] || { echo 'second run made a backup'; exit 1; }
    [ \"\$(sums)\" = \"\$a1\" ] || { echo 'skills, agents, ARIS or the codex MCP entry changed'; diff <(echo \"\$a1\") <(sums); exit 1; }
    $ADDONS
    echo SECOND-OK"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *SECOND-OK* ]]
  addons_ok
}

@test "hold file: no managed dotfile written" {
  run in_box "mkdir -p ~/.config/develop-env && : > ~/.config/develop-env/hold
    $BOOT; rc=\$?
    cmp /etc/skel/.bashrc ~/.bashrc || echo 'bashrc changed'
    [ ! -e ~/.config/fish/fish_plugins ] || echo 'fish_plugins written'
    grep -q 'github.com' ~/.ssh/known_hosts 2>/dev/null || echo 'known_hosts not written'
    echo \"rc=\$rc\""
  echo "$output"
  [[ "$output" == *"hold file present: not applying dotfiles"* ]]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" != *"bashrc changed"* ]]
  [[ "$output" != *"fish_plugins written"* ]]
  [[ "$output" != *"known_hosts not written"* ]]
}

@test "nfs home: warns and applies" {
  run in_box -e DEVENV_FAKE_FSTYPE=nfs4 "$BOOT"
  echo "$output"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^warning:.*network'
  no_fail_lines
  [[ "$output" == *"PASS fish_present"* ]]
}

@test "apply backs up changed files" {
  run in_box "$BOOT >/tmp/b.log 2>&1; rc=\$?; cat /tmp/b.log
    cmp /etc/skel/.bashrc ~/.dotfiles-backup-*/.bashrc && echo BACKUP-OK
    [ \"\$(stat -c %a ~/.dotfiles-backup-*)\" = 700 ] && echo BACKUP-MODE-OK
    case \"\$(readlink ~/.local/bin/tmux)\" in */envs/cli-tools/bin/tmux) echo TMUX-ENV-OK ;; esac
    exit \$rc"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *BACKUP-OK* ]]
  [[ "$output" == *BACKUP-MODE-OK* ]]
  [[ "$output" == *TMUX-ENV-OK* ]]   # this image has no system tmux
  [[ "$output" == *"/.dotfiles-backup-"* ]]
}

@test "apply never deletes old tools" {
  run in_box "set -u
    mkdir -p ~/.nvm ~/.local/fish-env/bin ~/.local/node-v20.0.0-linux-x64/bin ~/.local/bin
    : > ~/.nvm/nvm.sh
    printf '#!/bin/sh\necho old\n' > ~/.local/fish-env/bin/fish; chmod +x ~/.local/fish-env/bin/fish
    printf '#!/bin/sh\necho old\n' > ~/.local/node-v20.0.0-linux-x64/bin/node
    ln -s node-v20.0.0-linux-x64 ~/.local/node
    ln -s ../node/bin/node ~/.local/bin/node
    ln -s ../fish-env/bin/fish ~/.local/bin/fish
    $BOOT >/tmp/b.log 2>&1 || { cat /tmp/b.log; echo 'bootstrap failed'; exit 1; }
    for p in ~/.nvm/nvm.sh ~/.local/fish-env/bin/fish ~/.local/node-v20.0.0-linux-x64/bin/node; do
      [ -e \"\$p\" ] || { echo \"apply deleted \$p\"; exit 1; }
    done
    cl=~/.local/share/chezmoi/bin/cleanup
    echo n | \$cl > /tmp/c1.log 2>&1; cat /tmp/c1.log
    grep -q '.nvm' /tmp/c1.log || { echo 'cleanup did not list ~/.nvm'; exit 1; }
    [ -e ~/.nvm/nvm.sh ] || { echo 'cleanup removed without yes'; exit 1; }
    \$cl --yes || { echo 'cleanup --yes failed'; exit 1; }
    for p in ~/.nvm ~/.local/fish-env ~/.local/node-v20.0.0-linux-x64 ~/.local/node; do
      { [ -e \"\$p\" ] || [ -L \"\$p\" ]; } && { echo \"cleanup kept \$p\"; exit 1; }
    done
    # apply re-pointed ~/.local/bin/node at fnm's default; cleanup keeps that live link
    case \"\$(readlink -f ~/.local/bin/node)\" in */fnm/*) ;; *) echo 'node link not on fnm'; exit 1 ;; esac
    ~/.local/bin/fish --version || { echo 'fish link broken after cleanup'; exit 1; }
    echo OLD-TOOLS-OK"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *OLD-TOOLS-OK* ]]
}

@test "update after a dirty lock does not conflict" {
  run in_box "set -u
    cp -a /repo /tmp/upstream
    sh /repo/bootstrap.sh --source /tmp/upstream --role server --ci >/tmp/b.log 2>&1 \
      || { cat /tmp/b.log; echo 'bootstrap failed'; exit 1; }
    lock=home/.chezmoidata/versions.yaml
    echo '# local edit' >> ~/.local/share/chezmoi/\$lock
    sed -i 's/^resolved_at:.*/resolved_at: \"2000-01-01T00:00:00Z\"/' /tmp/upstream/\$lock
    git -C /tmp/upstream -c user.name=t -c user.email=t@example.invalid commit -qam 'advance lock'
    ~/.local/share/chezmoi/bin/update --ci; rc=\$?
    [ \"\$(git -C ~/.local/share/chezmoi rev-parse HEAD)\" = \"\$(git -C /tmp/upstream rev-parse HEAD)\" ] \
      || echo 'source clone not at upstream HEAD'
    echo \"update-rc=\$rc\""
  echo "$output"
  [[ "$output" == *"update-rc=0"* ]]
  [[ "$output" != *"not at upstream HEAD"* ]]
}

@test "missing bzip2 is printed as a command, not run" {
  run in_box "$BOOT; rc=\$?
    PATH=\$HOME/.local/bin:\$PATH command -v bzip2 && echo 'bzip2 installed'
    echo \"rc=\$rc\""
  echo "$output"
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"sudo apt install bzip2"* ]]
  [[ "$output" != *"sudo apt install curl"* ]]
  [[ "$output" != *"bzip2 installed"* ]]
  [[ "$output" != *"sudo: not found"* ]]
  [[ "$output" != *"sudo: command not found"* ]]
}

@test "system tmux stays first on PATH; the env still has tmux" {
  BOX_IMG="$IMG_TMUX" run in_box "$BOOT; rc=\$?
    echo \"tmux-on-path=\$(PATH=\$HOME/.local/bin:\$PATH command -v tmux)\"
    [ -x ~/micromamba/envs/cli-tools/bin/tmux ] && echo ENV-TMUX-OK
    echo \"rc=\$rc\""
  echo "$output"
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"tmux-on-path=/usr/bin/tmux"* ]]
  [[ "$output" == *ENV-TMUX-OK* ]]
  [[ "$output" == *"PASS tmux_version"* ]]
  no_fail_lines
}

@test "ssh key created once" {
  run in_box "$BOOT; rc=\$?
    fp1=\$(ssh-keygen -lf ~/.ssh/id_ed25519.pub)
    echo \"fp1=\$fp1\"
    sh /repo/bootstrap.sh --source /repo --role server --ci >/tmp/2.log 2>&1
    fp2=\$(ssh-keygen -lf ~/.ssh/id_ed25519.pub)
    [ \"\$fp1\" = \"\$fp2\" ] && echo KEY-UNCHANGED
    echo \"modes=\$(stat -c %a ~/.ssh) \$(stat -c %a ~/.ssh/authorized_keys)\"
    echo \"rc=\$rc\""
  echo "$output"
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"PASS ssh_key"* ]]
  [[ "$output" == *"SKIP github_ssh_auth"* ]]
  [[ "$output" == *KEY-UNCHANGED* ]]
  [[ "$output" == *"modes=700 600"* ]]
  no_fail_lines
}

@test "codex install in container" {
  run in_box "$BOOT >/tmp/b.log 2>&1; echo \"boot-rc=\$?\"
    export PATH=\$HOME/.local/bin:\$PATH
    echo \"codex-version=\$(codex --version 2>/dev/null)\"
    # bootstrap re-resolves the lock inside the container: compare with the lock it used
    echo \"codex-lock=\$(sed -n 's/^  codex: *//p' ~/.local/share/chezmoi/home/.chezmoidata/versions.yaml)\"
    c=~/.codex/config.toml
    s1=\$(sha256sum \$c)
    d=\$(chezmoi diff --no-pager 2>/dev/null); [ -z \"\$d\" ] && echo DIFF-EMPTY || echo \"diff after bootstrap: \$d\"
    # rerun the install script and the merge: nothing changes
    chezmoi execute-template < ~/.local/share/chezmoi/home/.chezmoiscripts/run_onchange_after_55-codex.sh.tmpl > /tmp/x.sh
    sh /tmp/x.sh > /tmp/x.log 2>&1; echo \"rerun-rc=\$?\"; cat /tmp/x.log
    chezmoi apply --no-tty >/dev/null 2>&1
    [ \"\$(sha256sum \$c)\" = \"\$s1\" ] && echo CONFIG-STABLE
    echo \"servers=\$(grep -c '^\[mcp_servers\.[^.]*\]\$' \$c) timeouts=\$(grep -c '^tool_timeout_sec = [0-9][0-9]*\$' \$c)\"
    sed -n '/^\[mcp_servers\.openaiDeveloperDocs\]\$/,/^\[/p' \$c | grep -qx 'tool_timeout_sec = 60' && echo ODD-TIMEOUT-60
    grep -nE '\"/|/home/' \$c && echo ABSOLUTE-IN-CONFIG
    codex mcp list 2>/dev/null
    for l in ~/.codex/skills/*; do
      [ -L \"\$l\" ] || continue
      case \"\$(readlink \"\$l\")\" in /*) echo \"ABSOLUTE-LINK \$l\" ;; esac
      [ -f \"\$l/SKILL.md\" ] || echo \"BROKEN-LINK \$l\"
    done
    echo \"links=\$(find ~/.codex/skills -maxdepth 1 -type l | wc -l)\"
    [ -s ~/.codex/agents/codebase-memory.toml ] && echo CBM-AGENT-OK
    ~/.local/share/chezmoi/bin/doctor --ci; echo \"doctor-rc=\$?\""
  echo "$output"
  [[ "$output" == *"boot-rc=0"* ]]
  used="$(printf '%s\n' "$output" | sed -n 's/^codex-lock=//p')"
  [ -n "$used" ]
  [[ "$output" == *"codex-version=codex-cli $used"* ]]
  [[ "$output" == *DIFF-EMPTY* ]]
  [[ "$output" == *"rerun-rc=0"* ]]
  [[ "$output" == *CONFIG-STABLE* ]]
  [[ "$output" == *"servers=6 timeouts=6"* ]]   # every server, the url one included
  [[ "$output" == *ODD-TIMEOUT-60* ]]
  [[ "$output" != *ABSOLUTE-IN-CONFIG* ]]
  [[ "$output" != *ABSOLUTE-LINK* ]]
  [[ "$output" != *BROKEN-LINK* ]]
  [[ "$output" == *CBM-AGENT-OK* ]]
  for s in semble codebase-memory-mcp drawio graphify paper-search openaiDeveloperDocs; do
    printf '%s\n' "$output" | grep -qE "^$s +"
  done
  for c in codex_installed codex_mcp codex_skills; do [[ "$output" == *"PASS $c"* ]]; done
  [[ "$output" == *"SKIP codex_login"* ]]
  [[ "$output" == *"doctor-rc=0"* ]]
  no_fail_lines
}
