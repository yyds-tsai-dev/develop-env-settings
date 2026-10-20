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

@test "server bootstrap in container ends with doctor PASS" {
  # Same as the README one-liner: the script arrives on stdin.
  run in_box 'cat /repo/bootstrap.sh | sh -s -- --source /repo --role server --ci'
  echo "$output"
  [ "$status" -eq 0 ]
  no_fail_lines
  for c in micromamba_envs cli_tools_linked node_default uv_tools fish_present fisher_tide; do
    [[ "$output" == *"PASS $c"* ]]
  done
}

@test "second bootstrap changes nothing" {
  run in_box "set -u
    $BOOT >/tmp/1.log 2>&1 || { cat /tmp/1.log; echo 'first bootstrap failed'; exit 1; }
    cm=\$HOME/.local/bin/chezmoi; mm=\$HOME/.local/bin/micromamba
    n1=\$(grep -c PATH ~/.bashrc); e1=\$(\$mm env list); b1=\$(ls -d ~/.dotfiles-backup-* | wc -l)
    d=\$(\$cm diff --no-pager 2>/dev/null); [ -z \"\$d\" ] || { echo \"diff after first: \$d\"; exit 1; }
    sleep 1
    $BOOT >/tmp/2.log 2>&1 || { cat /tmp/2.log; echo 'second bootstrap failed'; exit 1; }
    d=\$(\$cm diff --no-pager 2>/dev/null); [ -z \"\$d\" ] || { echo \"diff after second: \$d\"; exit 1; }
    [ \"\$(grep -c PATH ~/.bashrc)\" = \"\$n1\" ] || { echo 'PATH line count changed'; exit 1; }
    [ \"\$(\$mm env list)\" = \"\$e1\" ] || { echo 'micromamba env list changed'; exit 1; }
    [ \"\$(ls -d ~/.dotfiles-backup-* | wc -l)\" = \"\$b1\" ] || { echo 'second run made a backup'; exit 1; }
    echo SECOND-OK"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *SECOND-OK* ]]
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
    for p in ~/.nvm ~/.local/fish-env ~/.local/node-v20.0.0-linux-x64 ~/.local/node ~/.local/bin/node; do
      { [ -e \"\$p\" ] || [ -L \"\$p\" ]; } && { echo \"cleanup kept \$p\"; exit 1; }
    done
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
