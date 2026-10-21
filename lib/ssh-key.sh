#!/usr/bin/env bash
# GitHub SSH key step. Usage: lib/ssh-key.sh [--ci]
# Called by the run_once_after_40-ssh-key script and by bin/machine-local (so a
# hold-file home also gets a key). Idempotent: an existing key is never touched.
#   1. ~/.ssh/id_ed25519 missing: create it (no passphrase).
#   2. Newly created key, interactive: print the public key and the GitHub URL,
#      wait for Enter. Non-interactive (--ci, or stdin not a TTY): print them and
#      do not wait.
#   3. `ssh -T git@github.com` (BatchMode, 10 s timeout). "successfully
#      authenticated" is success; anything else is a warning, never a failure.
# Always exits 0.
set -u

KEY="$HOME/.ssh/id_ed25519"
URL="https://github.com/settings/ssh/new"
ci=0
[ "${1:-}" = --ci ] && ci=1
[ "${CI:-}" = true ] && ci=1
[ -t 0 ] || ci=1

warn() { echo "warning: $*" >&2; }

created=0
if [ ! -e "$KEY" ]; then
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    warn "ssh-keygen not found; no GitHub SSH key created"
    exit 0
  fi
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  if ssh-keygen -q -t ed25519 -C "$(id -un)@$(hostname)" -N "" -f "$KEY" >/dev/null; then
    created=1
  else
    warn "ssh-keygen failed; no GitHub SSH key created"
    exit 0
  fi
fi

if [ "$created" -eq 1 ]; then
  echo "Created $KEY. Add this public key to GitHub at $URL"
  cat "$KEY.pub"
  if [ "$ci" -eq 0 ]; then
    printf 'Press Enter once the key is added to GitHub... '
    read -r _ || true
  fi
fi

command -v ssh >/dev/null 2>&1 || { warn "ssh not found; GitHub authentication not checked"; exit 0; }
out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         git@github.com 2>&1 </dev/null)"
case "$out" in
  *"successfully authenticated"*) echo "GitHub SSH authentication works" ;;
  *)
    warn "GitHub SSH authentication failed; add this public key at $URL"
    [ -r "$KEY.pub" ] && cat "$KEY.pub" >&2
    ;;
esac
exit 0
