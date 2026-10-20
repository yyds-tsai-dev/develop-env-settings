#!/usr/bin/env bash
# Shared tail of bootstrap.sh and bin/update. Usage: lib/apply.sh [--ci]
#
# 1. Hold file (~/.config/develop-env/hold): print the notice, run only
#    bin/machine-local, exit 0.
# 2. Resolve the Version lock (a failure keeps the committed lock).
# 3. Warn, and continue, when the home is on network storage or the account has
#    processes older than 10 minutes (other than shells, tmux, sshd, the VS Code
#    server, claude, codex and this script's own process tree).
# 4. Back up every existing target `chezmoi status` reports as changing into
#    ~/.dotfiles-backup-<YYYYmmdd-HHMMSS>/ (same relative paths).
# 5. chezmoi apply, bin/machine-local, bin/doctor. Exit status: 1 if apply
#    failed, else Doctor's.
# Bash 3.2 compatible (macOS).
set -u

APPLY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

warn() { echo "warning: $*" >&2; }

# long_running_processes [SELF_PID]: print "<pid> <name>" for each process of this
# user running longer than 10 minutes that is not exempt (see header) and not an
# ancestor or descendant of SELF_PID (default: this shell). Prints nothing when
# ps is unavailable.
long_running_processes() {
  local self="${1:-$$}" fmt=etimes table
  command -v ps >/dev/null 2>&1 || return 0
  ps -o etimes= -p "$$" >/dev/null 2>&1 || fmt=etime
  table="$(ps -u "$(id -u)" -o pid=,ppid=,"$fmt"=,args= 2>/dev/null)" || return 0
  printf '%s\n' "$table" | awk -v self="$self" '
    function secs(t,   d, n, a, s, i) {
      d = 0
      if (t ~ /^[0-9]+$/) return t + 0
      if (index(t, "-")) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
      n = split(t, a, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + a[i]
      return d * 86400 + s
    }
    NF >= 4 {
      pid = $1; ppid[pid] = $2; et[pid] = secs($3)
      $1 = ""; $2 = ""; $3 = ""; sub(/^ +/, ""); args[pid] = $0; order[++n] = pid
    }
    END {
      p = self
      while ((p in ppid) && !(p in anc)) { anc[p] = 1; p = ppid[p] }
      anc[self] = 1; desc[self] = 1
      do {
        changed = 0
        for (i = 1; i <= n; i++) {
          q = order[i]
          if (!(q in desc) && (ppid[q] in desc)) { desc[q] = 1; changed = 1 }
        }
      } while (changed)
      for (i = 1; i <= n; i++) {
        q = order[i]
        if ((q in anc) || (q in desc) || et[q] < 600) continue
        if (args[q] ~ /\.vscode-server/) continue
        split(args[q], w, " "); name = w[1]
        sub(/.*\//, "", name); sub(/^-/, "", name); sub(/:$/, "", name)
        if (name ~ /^(bash|sh|dash|zsh|fish|tcsh|csh|ksh|tmux|sshd|claude|codex)$/) continue
        print q, name
      }
    }'
}

# backup_changed: copy existing targets that apply will change; print the dir.
backup_changed() {
  local status line path dir n=0
  status="$(chezmoi status --exclude=scripts 2>/dev/null)" || status=
  dir="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line:1:1}" != " " ] || continue
    path="${line:3}"
    [ -f "$HOME/$path" ] || [ -L "$HOME/$path" ] || continue
    mkdir -p "$dir/$(dirname "$path")"
    cp -pP "$HOME/$path" "$dir/$path" || { warn "could not back up $HOME/$path"; continue; }
    n=$((n + 1))
  done <<EOF
$status
EOF
  if [ "$n" -gt 0 ]; then
    echo "backed up $n file(s) that apply will change to $dir"
  else
    echo "nothing to back up: apply changes no existing file"
  fi
}

apply_main() {
  local ci= procs apply_rc=0 doctor_rc=0
  [ "${1:-}" = --ci ] && ci=--ci
  PATH="$HOME/.local/bin:$PATH"; export PATH

  if [ -e "$HOME/.config/develop-env/hold" ] \
     || [ "$(chezmoi execute-template '{{ .hold }}' 2>/dev/null)" = true ]; then
    echo "hold file present: not applying dotfiles"
    "$APPLY_ROOT/bin/machine-local"
    return 0
  fi

  echo "resolving the version lock"
  uv run --script "$APPLY_ROOT/lib/resolve_versions.py" \
      --manifest "$APPLY_ROOT/home/.chezmoidata/manifest.yaml" \
      --lock "$APPLY_ROOT/home/.chezmoidata/versions.yaml" \
    || warn "version lock resolve failed; keeping the committed lock"

  if [ "$(chezmoi execute-template '{{ .sharedHome }}' 2>/dev/null)" = true ]; then
    warn "home directory $HOME is on network storage (NFS): every machine that mounts it sees these dotfiles; applying anyway"
  fi
  procs="$(long_running_processes "$$" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ -n "$procs" ]; then
    warn "processes running for more than 10 minutes: $procs; applying anyway"
  fi

  backup_changed

  if [ -n "$ci" ]; then
    chezmoi apply --force --no-tty || apply_rc=$?
  else
    chezmoi apply --force || apply_rc=$?
  fi
  [ "$apply_rc" -eq 0 ] || echo "error: chezmoi apply failed (exit $apply_rc)" >&2

  "$APPLY_ROOT/bin/machine-local"

  "$APPLY_ROOT/bin/doctor" $ci || doctor_rc=$?
  [ "$apply_rc" -eq 0 ] || return 1
  return "$doctor_rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  apply_main "$@"
  exit $?
fi
