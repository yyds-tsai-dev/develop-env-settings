#!/usr/bin/env bats
# Host-side tests for the Linux Server tool layer: rendered install scripts,
# cleanup, machine-local and the pre-apply process filter. Every test works in a
# sandbox HOME with stubbed tools; nothing is installed and the real $HOME is
# never touched. bootstrap.bats runs the real thing in Docker.

load helpers

setup() {
  [ "$(uname -s)" = Linux ] || skip "linux server tool layer"
  new_sandbox
  H="$SB/h"; STUB="$SB/stub"; mkdir -p "$H" "$STUB"
}
teardown() { rm -rf "$SB"; }

# render SCRIPT_BASENAME: render a home/.chezmoiscripts template for the server role.
render() {
  init_role server >&2
  chezmoi_iso execute-template \
    < "$REPO_ROOT/home/.chezmoiscripts/$1" > "$SB/$1.out"
  echo "$SB/$1.out"
}

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

@test "rendered install scripts parse" {
  for s in run_once_before_00-prereqs.sh.tmpl run_onchange_after_10-micromamba-envs.sh.tmpl \
           run_onchange_after_15-symlinks.sh.tmpl run_onchange_after_20-node.sh.tmpl \
           run_onchange_after_30-uv-tools.sh.tmpl; do
    f="$(render "$s")"
    [ -s "$f" ]
    head -n1 "$f" | grep -q '^#!/bin/sh'
    sh -n "$f"
  done
}

@test "bootstrap.sh is POSIX sh; update, cleanup, machine-local and lib parse" {
  sh -n "$REPO_ROOT/bootstrap.sh"
  if command -v dash >/dev/null; then dash -n "$REPO_ROOT/bootstrap.sh"; fi
  for f in bin/update bin/cleanup bin/machine-local lib/apply.sh doctor.d/10-tools.sh; do
    bash -n "$REPO_ROOT/$f"
  done
  [ -x "$REPO_ROOT/bootstrap.sh" ] && [ -x "$REPO_ROOT/bin/update" ] \
    && [ -x "$REPO_ROOT/bin/cleanup" ] && [ -x "$REPO_ROOT/bin/machine-local" ]
}

@test "micromamba script pins locked versions and never removes envs" {
  f="$(render run_onchange_after_10-micromamba-envs.sh.tmpl)"
  grep -q 'fish==4.9.3' "$f"
  grep -q 'tmux==3.8_' "$f"
  grep -q 'poppler==' "$f"
  grep -q 'cli-tools' "$f"
  grep -q 'pdftools' "$f"
  run grep -Eq 'micromamba[^#]*(remove|uninstall)|rm -rf' "$f"; [ "$status" -ne 0 ]
}

@test "micromamba script retries a failing pin unpinned with a warning" {
  f="$(render run_onchange_after_10-micromamba-envs.sh.tmpl)"
  mkdir -p "$H/.local/bin"
  cat > "$H/.local/bin/micromamba" <<'EOF'
#!/bin/sh
echo "$*" >> "$HOME/mm.log"
case "$1" in --version) echo 2.9.0; exit 0 ;; esac
for a in "$@"; do [ "$a" = "tmux==3.8_" ] && exit 1; done
prev=; for a in "$@"; do [ "$prev" = -n ] && mkdir -p "$MAMBA_ROOT_PREFIX/envs/$a"; prev="$a"; done
exit 0
EOF
  chmod +x "$H/.local/bin/micromamba"
  mkdir -p "$H/micromamba/envs/pdftools"   # existing env: must be installed into, not created
  run env -i HOME="$H" PATH="/usr/bin:/bin" sh "$f"
  echo "$output"; cat "$H/mm.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning:"*"tmux"* ]]
  grep -Eq '(^| )tmux( |$)' "$H/mm.log"
  grep -q 'create .*-n cli-tools' "$H/mm.log"
  run grep -q 'create .*-n pdftools' "$H/mm.log"; [ "$status" -ne 0 ]
  grep -q 'install .*-n pdftools' "$H/mm.log"
}

@test "symlinks script links only manifest package binaries" {
  f="$(render run_onchange_after_15-symlinks.sh.tmpl)"
  e="$H/micromamba/envs/cli-tools"; mkdir -p "$e/bin" "$e/conda-meta" "$H/micromamba/envs/pdftools/bin"
  for b in fish fish_indent rg bzip2 openssl; do printf '#!/bin/sh\n' > "$e/bin/$b"; chmod +x "$e/bin/$b"; done
  printf '{\n "files": [\n  "bin/fish",\n  "bin/fish_indent",\n  "share/x"\n ]\n}\n' > "$e/conda-meta/fish-4.9.3-h0_0.json"
  printf '{"files": ["bin/rg"]}\n' > "$e/conda-meta/ripgrep-15.2.0-h0_1.json"
  printf '{"files": ["bin/bzip2"]}\n' > "$e/conda-meta/bzip2-1.0.8-h0_10.json"
  mkdir -p "$H/.local/bin"; ln -s /nonexistent/old-fish "$H/.local/bin/fish"
  printf 'keep\n' > "$H/.local/bin/rg"   # a regular file is never replaced
  run env -i HOME="$H" PATH="/usr/bin:/bin" sh "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(readlink "$H/.local/bin/fish")" = "$e/bin/fish" ]
  [ "$(readlink "$H/.local/bin/fish_indent")" = "$e/bin/fish_indent" ]
  [ "$(cat "$H/.local/bin/rg")" = keep ]
  [[ "$output" == *"warning:"*"rg"* ]]
  [ ! -e "$H/.local/bin/bzip2" ]
  [ ! -e "$H/.local/bin/openssl" ]
}

@test "prereqs script prints missing packages as an apt command and exits 0" {
  f="$(render run_once_before_00-prereqs.sh.tmpl)"
  for t in curl git tar; do stub "$t" 'exit 0'; done
  run env -i HOME="$H" PATH="$STUB" /bin/sh "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sudo apt install bzip2"* ]]
  [[ "$output" != *"apt install curl"* ]]
}

@test "node script pins the manifest major via fnm" {
  f="$(render run_onchange_after_20-node.sh.tmpl)"
  grep -q 'fnm install 24' "$f"
  grep -q 'fnm default 24' "$f"
  grep -q '1.39.0' "$f"
}

@test "node script links the fnm default node/npm/npx/corepack, never over a regular file" {
  f="$(render run_onchange_after_20-node.sh.tmpl)"
  fd="$H/.local/share/fnm"; v="$fd/node-versions/v24.0.0/installation/bin"
  mkdir -p "$v" "$fd/aliases" "$H/.local/bin"
  ln -s ../node-versions/v24.0.0/installation "$fd/aliases/default"
  for t in node npm npx corepack; do printf '#!/bin/sh\n' > "$v/$t"; chmod +x "$v/$t"; done
  printf '#!/bin/sh\ncase "$1" in\n  --version) echo "fnm 1.39.0" ;;\n  exec) shift 3; PATH="%s:$PATH" "$@" ;;\nesac\n' "$v" > "$H/.local/bin/fnm"
  chmod +x "$H/.local/bin/fnm"
  echo keep > "$H/.local/bin/corepack"
  run env HOME="$H" PATH="/usr/bin:/bin" sh "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  for t in node npm npx; do
    [ "$(readlink "$H/.local/bin/$t")" = "$fd/aliases/default/bin/$t" ]
  done
  [ "$(cat "$H/.local/bin/corepack")" = keep ]
  [[ "$output" == *"corepack is a regular file"* ]]
  run env HOME="$H" PATH="/usr/bin:/bin" sh "$f"   # idempotent
  [ "$status" -eq 0 ]
  [ "$(readlink "$H/.local/bin/npx")" = "$fd/aliases/default/bin/npx" ]
}

@test "uv tools script installs the locked specs" {
  f="$(render run_onchange_after_30-uv-tools.sh.tmpl)"
  grep -q 'semble\[mcp\]==0.7.0' "$f"
  grep -q 'graphifyy\[mcp\]==0.9.92' "$f"
  grep -q 'paper-search-mcp==0.1.4' "$f"
}

@test "cleanup lists old tools, keeps them on N, removes them with --yes" {
  mkdir -p "$H/.nvm" "$H/.local/fish-env/bin" "$H/.local/node-v20.1.0-linux-x64/bin" \
           "$H/.local/bin" "$H/micromamba/envs/fish-env" "$H/micromamba/envs/cli-tools/bin"
  : > "$H/.nvm/nvm.sh"; : > "$H/.local/fish-env/bin/fish"; : > "$H/micromamba/envs/cli-tools/bin/rg"
  ln -s node-v20.1.0-linux-x64 "$H/.local/node"
  ln -s ../node/bin/node "$H/.local/bin/node"
  ln -s /nonexistent/thing "$H/.local/bin/gone"
  ln -s "$H/micromamba/envs/cli-tools/bin/rg" "$H/.local/bin/rg"
  run env HOME="$H" bash -c 'echo n | "$1"' _ "$REPO_ROOT/bin/cleanup"
  echo "$output"
  for p in .nvm .local/fish-env micromamba/envs/fish-env .local/node-v20.1.0-linux-x64 .local/node .local/bin/gone; do
    [[ "$output" == *"$p"* ]]
  done
  [ -e "$H/.nvm/nvm.sh" ] && [ -L "$H/.local/bin/gone" ]
  run env HOME="$H" "$REPO_ROOT/bin/cleanup" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  for p in .nvm .local/fish-env micromamba/envs/fish-env .local/node-v20.1.0-linux-x64 .local/node .local/bin/node .local/bin/gone; do
    [ ! -e "$H/$p" ] && [ ! -L "$H/$p" ]
  done
  [ -L "$H/.local/bin/rg" ] && [ -e "$H/micromamba/envs/cli-tools/bin/rg" ]
  run env HOME="$H" "$REPO_ROOT/bin/cleanup" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to clean up"* ]]
}

@test "machine-local merges github.com known_hosts without duplicates" {
  stub ssh-keyscan 'echo "github.com ssh-ed25519 AAAAED"; echo "github.com ecdsa-sha2-nistp256 AAAAEC"'
  mkdir -p "$H/.ssh"
  printf 'other.example ssh-rsa AAAAOTHER\n|1|hashed= ssh-ed25519 AAAAED\n' > "$H/.ssh/known_hosts"
  run env HOME="$H" PATH="$STUB:/usr/bin:/bin" "$REPO_ROOT/bin/machine-local"
  [ "$status" -eq 0 ]
  run env HOME="$H" PATH="$STUB:/usr/bin:/bin" "$REPO_ROOT/bin/machine-local"
  [ "$status" -eq 0 ]
  cat "$H/.ssh/known_hosts"
  [ "$(head -n1 "$H/.ssh/known_hosts")" = "other.example ssh-rsa AAAAOTHER" ]
  [ "$(grep -c 'AAAAED' "$H/.ssh/known_hosts")" -eq 1 ]
  [ "$(grep -c 'AAAAEC' "$H/.ssh/known_hosts")" -eq 1 ]
}

@test "machine-local warns and exits 0 when ssh-keyscan fails" {
  stub ssh-keyscan 'exit 1'
  run env HOME="$H" PATH="$STUB:/usr/bin:/bin" "$REPO_ROOT/bin/machine-local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning:"* ]]
}

@test "long-running process filter skips shells, tmux, sshd, vscode, agents and own tree" {
  # Fixture columns: pid ppid etimes args. Own pid is 500 (its parent 400, child 501).
  cat > "$STUB/ps" <<'EOF'
#!/bin/sh
cat <<'T'
  400     1  9000 /usr/bin/python3 -m outer_runner
  500   400  9000 bash /x/lib/apply.sh
  501   500  9000 sleep 1
  100     1  9000 -bash
  101     1  9000 tmux new -s main
  102     1  9000 sshd: dev@pts/0
  103     1  9000 /home/x/.vscode-server/bin/abc/node server.js
  104     1  9000 claude
  105     1  9000 /usr/local/bin/codex exec
  106     1  9000 /usr/bin/fish
  200     1  9000 python3 train.py
  201     1    30 make -j8
T
EOF
  chmod +x "$STUB/ps"
  run env PATH="$STUB:/usr/bin:/bin" bash -c '. "$1"; long_running_processes 500' _ "$REPO_ROOT/lib/apply.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "200 python3" ]
}

@test "doctor tools checks register" {
  DOCTOR_ONLY='10-*' run "$REPO_ROOT/bin/doctor" --ci
  for c in micromamba_envs cli_tools_linked node_default uv_tools; do
    [[ "$output" == *"$c"* ]]
  done
}

@test "cleanup: plain files matching the globs are targets, live env links survive" {
  e="$H/micromamba/envs/cli-tools"; u="$H/.local/share/uv/tools/semble/bin"
  mkdir -p "$H/.local/bin" "$e/bin" "$u"
  : > "$H/.local/node-v20.11.0-linux-x64.tar.xz"
  : > "$H/.nvm"
  : > "$e/bin/rg"; : > "$u/semble"
  ln -s "$e/bin/rg" "$H/.local/bin/rg"
  ln -s "$u/semble" "$H/.local/bin/semble"
  run env HOME="$H" bash -c 'echo n | "$1"' _ "$REPO_ROOT/bin/cleanup"
  echo "$output"
  [[ "$output" == *"node-v20.11.0-linux-x64.tar.xz"* ]]
  [[ "$output" == *"/.nvm"* ]]
  [[ "$output" != *".local/bin/rg"* ]]
  [[ "$output" != *".local/bin/semble"* ]]
  run env HOME="$H" "$REPO_ROOT/bin/cleanup" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$H/.local/node-v20.11.0-linux-x64.tar.xz" ] && [ ! -e "$H/.nvm" ]
  [ -L "$H/.local/bin/rg" ] && [ -e "$H/.local/bin/rg" ]
  [ -L "$H/.local/bin/semble" ] && [ -e "$H/.local/bin/semble" ]
}

@test "apply: failing chezmoi status skips apply and exits non-zero" {
  src="$H/.local/share/chezmoi"; mkdir -p "$src"
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -xf - -C "$src"
  printf '{{ fail "deliberately broken" }}\n' > "$src/home/dot_broken.tmpl"
  stub uv 'exit 0'
  stub ssh-keyscan 'exit 1'
  run env -i HOME="$H" CI=true PATH="$STUB:$REPO_ROOT/.tools/bin:/usr/bin:/bin" \
    "$REPO_ROOT/.tools/bin/chezmoi" init --promptChoice role=server --no-tty
  [ "$status" -eq 0 ]
  run env -i HOME="$H" CI=true PATH="$STUB:$REPO_ROOT/.tools/bin:/usr/bin:/bin" \
    bash "$src/lib/apply.sh" --ci
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"warning: chezmoi status failed"*"deliberately broken"* ]]
  [[ "$output" == *"skipping chezmoi apply"* ]]
  [ ! -e "$H/.bashrc" ] && [ ! -e "$H/.tmux.conf" ] && [ ! -e "$H/.config/fish" ]
  [[ "$output" == *"PASS chezmoi_present"* ]]   # doctor still ran
}

@test "symlinks script leaves a system tmux first, links the env tmux otherwise" {
  f="$(render run_onchange_after_15-symlinks.sh.tmpl)"
  e="$H/micromamba/envs/cli-tools"; mkdir -p "$e/bin" "$e/conda-meta"
  printf '#!/bin/sh\n' > "$e/bin/tmux"; chmod +x "$e/bin/tmux"
  printf '{"files": ["bin/tmux"]}\n' > "$e/conda-meta/tmux-3.8_-h0_0.json"
  # A PATH with only the tools the script needs (no tmux anywhere).
  tb="$SB/toolbox"; mkdir -p "$tb"
  for t in sh grep tr sort readlink ln rm mkdir cat; do ln -s "$(command -v "$t")" "$tb/$t"; done
  run env -i HOME="$H" PATH="$H/.local/bin:$tb" sh "$f"
  [ "$status" -eq 0 ]
  [ "$(readlink "$H/.local/bin/tmux")" = "$e/bin/tmux" ]
  stub tmux 'echo system tmux'
  run env -i HOME="$H" PATH="$H/.local/bin:$STUB:$tb" sh "$f"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$H/.local/bin/tmux" ] && [ ! -L "$H/.local/bin/tmux" ]
  [[ "$output" == *"system tmux found"* ]]
}

@test "long-running process filter exempts children of session services and agents only" {
  cat > "$STUB/ps" <<'EOF2'
#!/bin/sh
cat <<'T'
  300     1  9000 /lib/systemd/systemd --user
  301   300  9000 (sd-pam)
  302   300  9000 /usr/bin/pipewire
  310     1  9000 ssh-agent -s
  311     1  9000 /home/x/.local/bin/claude
  312   311  9000 python3 tool_job.py
  320     1  9000 tmux new -s main
  321   320  9000 -bash
  322   321  9000 python3 train.py
T
EOF2
  chmod +x "$STUB/ps"
  run env PATH="$STUB:/usr/bin:/bin" bash -c '. "$1"; long_running_processes 999' _ "$REPO_ROOT/lib/apply.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "322 python3" ]
}

@test "bootstrap warns when an existing clone's origin differs from --source" {
  stub uv 'exit 0'
  stub chezmoi 'exit 7'   # stop right after the clone step
  wt="$H/.local/share/chezmoi"; mkdir -p "$wt"
  git -C "$wt" init -q && git -C "$wt" remote add origin /elsewhere
  run env -i HOME="$H" PATH="$STUB:/usr/bin:/bin" sh "$REPO_ROOT/bootstrap.sh" --source /repo --role server --ci
  echo "$output"
  [[ "$output" == *"warning: reusing existing clone"*"/elsewhere"*"/repo"* ]]
  run env -i HOME="$H" PATH="$STUB:/usr/bin:/bin" sh "$REPO_ROOT/bootstrap.sh" --source /elsewhere --role server --ci
  [[ "$output" != *"warning: reusing"* ]]
  run env -i HOME="$H" PATH="$STUB:/usr/bin:/bin" sh "$REPO_ROOT/bootstrap.sh" --role server --ci
  [[ "$output" != *"warning: reusing"* ]]
}
