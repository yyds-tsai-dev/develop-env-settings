#!/bin/sh
# Bootstrap: one command from a fresh machine to a Doctor-checked environment.
#
#   curl -fsSL https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.sh | sh
#   sh bootstrap.sh [--source REPO] [--role ROLE] [--ci]
#
# 1. Installs chezmoi and uv into ~/.local/bin if missing.
# 2. Clones REPO (a local path, a git URL or owner/repo on GitHub; default
#    yyds-tsai-dev/develop-env-settings) into chezmoi's source dir unless it is
#    already there, then runs `chezmoi init`.
# 3-5. lib/apply.sh: hold check, Version lock resolve, warnings, backup,
#    `chezmoi apply`, bin/machine-local, bin/doctor.
#
# --role: server | desktop | desktop+server (default on Linux: server; otherwise
#   chezmoi asks once). --ci: CI=true (non-interactive; enables CI test hooks) and
#   `bin/doctor --ci`.
# POSIX sh (the one-liner pipes it to sh). Never uses sudo: missing system
# packages are printed as commands. The body is one function so that `curl | sh`
# has read the whole script before anything runs.

bootstrap_main() {
    src=yyds-tsai-dev/develop-env-settings
    role=
    ci=
    while [ $# -gt 0 ]; do
        case "$1" in
            --source) [ $# -ge 2 ] || { echo "error: --source needs a value" >&2; return 2; }
                      src="$2"; shift 2 ;;
            --source=*) src="${1#--source=}"; shift ;;
            --role) [ $# -ge 2 ] || { echo "error: --role needs a value" >&2; return 2; }
                    role="$2"; shift 2 ;;
            --role=*) role="${1#--role=}"; shift ;;
            --ci) ci=1; shift ;;
            -h|--help) echo "usage: bootstrap.sh [--source REPO] [--role ROLE] [--ci]"; return 0 ;;
            *) echo "error: unknown argument: $1" >&2; return 2 ;;
        esac
    done
    if [ -n "$ci" ]; then CI=true; export CI; fi
    if [ -z "$role" ] && [ "$(uname -s)" = Linux ]; then role=server; fi

    bin="$HOME/.local/bin"
    mkdir -p "$bin"
    PATH="$bin:$PATH"
    export PATH

    # Prompts must not read the rest of a piped script: use the terminal or nothing.
    if [ -z "$ci" ] && (: </dev/tty) 2>/dev/null; then tty=/dev/tty; else tty=/dev/null; fi

    for t in curl git tar; do
        command -v "$t" >/dev/null 2>&1 || {
            echo "error: $t is required; ask an admin, or run: sudo apt install $t" >&2
            return 1
        }
    done

    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64)  cz=linux-amd64;  uvt=x86_64-unknown-linux-gnu ;;
        Linux-aarch64) cz=linux-arm64;  uvt=aarch64-unknown-linux-gnu ;;
        Darwin-arm64)  cz=darwin-arm64; uvt=aarch64-apple-darwin ;;
        Darwin-x86_64) cz=darwin-amd64; uvt=x86_64-apple-darwin ;;
        *) echo "error: unsupported platform $(uname -s) $(uname -m)" >&2; return 1 ;;
    esac

    if ! command -v chezmoi >/dev/null 2>&1; then
        echo "installing chezmoi into $bin"
        curl -fsSL --retry 3 -o "$bin/chezmoi.tmp" \
            "https://github.com/twpayne/chezmoi/releases/latest/download/chezmoi-$cz" \
            && chmod 0755 "$bin/chezmoi.tmp" && mv -f "$bin/chezmoi.tmp" "$bin/chezmoi" \
            || { rm -f "$bin/chezmoi.tmp"; echo "error: chezmoi download failed" >&2; return 1; }
    fi
    if ! command -v uv >/dev/null 2>&1; then
        echo "installing uv into $bin"
        tmp="$(mktemp -d)"
        if curl -fsSL --retry 3 "https://github.com/astral-sh/uv/releases/latest/download/uv-$uvt.tar.gz" \
            | tar -xzf - -C "$tmp"; then
            for f in uv uvx; do chmod 0755 "$tmp/uv-$uvt/$f" && mv -f "$tmp/uv-$uvt/$f" "$bin/$f"; done
            rm -rf "$tmp"
        else
            rm -rf "$tmp"; echo "error: uv download failed" >&2; return 1
        fi
    fi

    wt="${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi"
    if [ ! -e "$wt/.git" ]; then
        case "$src" in
            /*|./*|../*|*://*|*@*:*) url="$src" ;;
            */*) if [ -d "$src" ]; then url="$src"; else url="https://github.com/$src.git"; fi ;;
            *) url="$src" ;;
        esac
        echo "cloning $url into $wt"
        mkdir -p "$(dirname "$wt")"
        git clone -q "$url" "$wt" || { echo "error: git clone $url failed" >&2; return 1; }
    fi

    if [ -n "$ci" ]; then notty=--no-tty; else notty=; fi
    if [ -n "$role" ]; then
        chezmoi init $notty --promptChoice "role=$role" <"$tty" || return 1
    else
        chezmoi init $notty <"$tty" || return 1
    fi
    wt="$(chezmoi execute-template '{{ .chezmoi.workingTree }}')" || return 1

    if [ -n "$ci" ]; then
        exec bash "$wt/lib/apply.sh" --ci <"$tty"
    fi
    exec bash "$wt/lib/apply.sh" <"$tty"
}

bootstrap_main "$@"
