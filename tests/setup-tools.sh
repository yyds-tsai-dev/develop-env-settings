#!/usr/bin/env bash
# Download chezmoi and bats-core into .tools/ (repo-local; never touches ~).
# Idempotent: skips a tool that is already present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
mkdir -p "$TOOLS/bin"

uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux) os=linux; ext=tar.gz; exe= ;;
  Darwin) os=darwin; ext=tar.gz; exe= ;;
  MINGW*|MSYS*|CYGWIN*) os=windows; ext=zip; exe=.exe ;;
  *) echo "unsupported OS: $uname_s" >&2; exit 1 ;;
esac
case "$uname_m" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported arch: $uname_m" >&2; exit 1 ;;
esac

gh_latest_tag() {
  local auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL "${auth[@]}" "https://api.github.com/repos/$1/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1
}

if [ ! -x "$TOOLS/bin/chezmoi$exe" ]; then
  tag="$(gh_latest_tag twpayne/chezmoi)"
  ver="${tag#v}"
  tmp="$(mktemp -d)"
  url="https://github.com/twpayne/chezmoi/releases/download/$tag/chezmoi_${ver}_${os}_${arch}.$ext"
  curl -fsSL "$url" -o "$tmp/chezmoi.$ext"
  if [ "$ext" = zip ]; then
    mkdir -p "$tmp/x"
    tar -xf "$tmp/chezmoi.zip" -C "$tmp/x" chezmoi.exe 2>/dev/null \
      || powershell -NoProfile -Command "Expand-Archive -Force -Path '$(cygpath -w "$tmp/chezmoi.zip")' -DestinationPath '$(cygpath -w "$tmp/x")'"
  else
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/chezmoi.$ext" -C "$tmp/x" chezmoi
  fi
  install -m 0755 "$tmp/x/chezmoi$exe" "$TOOLS/bin/chezmoi$exe"
  rm -rf "$tmp"
fi

if [ ! -x "$TOOLS/bin/bats" ]; then
  tag="$(gh_latest_tag bats-core/bats-core)"
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/$tag.tar.gz" -o "$tmp/bats.tgz"
  tar -xzf "$tmp/bats.tgz" -C "$tmp"
  "$tmp"/bats-core-*/install.sh "$TOOLS" >/dev/null
  rm -rf "$tmp"
fi

echo "tools ready in $TOOLS"
