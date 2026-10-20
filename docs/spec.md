# develop-env-settings: specification

Status: agreed in the 2026-10-18 grilling session; awaiting final confirmation before implementation.
Vocabulary: see [GLOSSARY.md](../GLOSSARY.md). Decisions with lasting trade-offs: [docs/adr/](adr/).

## Goal

On a new machine, one Bootstrap command (or an agent following `AGENTS.md`) produces the same Personal environment the person has today on their lab Server, and Doctor confirms it. Daily development is VS Code Remote-SSH from a Desktop; WezTerm is the occasional CLI-only path.

## Scope

In: VS Code (Remote-SSH server side + Desktop client pieces), tmux, fish (fisher plugins, tide prompt), micromamba, uv (+ uv tools), fnm/Node, git (+ git-lfs, gh), Claude Code (user CLAUDE.md, settings, hooks, status line, generic agents, plugins, skills, MCP servers), Codex (AGENTS.md, config, generic agents, skills, MCP servers), SSH (`authorized_keys`, key generation), WezTerm, Nerd Font, Bitwarden CLI.

Out: project toolchains and secrets (DREAMPlace, OpenROAD, CUDA, Innovus, project `.venv`, `~/.config/ioplace/nvl4.pw`), project `.claude/`/`.codex/` agent overrides (left untouched), Claude project memory (`~/.claude/projects`), state directories (`~/.codex` sessions, `~/.vscode-server` data, caches).

## Machine roles

| Role | OS | Gets |
|---|---|---|
| Server | Linux x86_64, no admin rights | Full environment, all under userland paths |
| Desktop | Windows, macOS | VS Code client pieces, WezTerm, git, gh, SSH client + key, Nerd Font, Bitwarden CLI |
| Desktop + Server | macOS (opt-in) | Both, Server tools via Homebrew |
| Server via WSL2 | Windows | Treated as a Linux Server |

Shared home: when the home directory is on a network filesystem (NFS), Bootstrap never applies dotfiles, because that would change every machine mounting it; it runs only the machine-local steps (SSH key, `known_hosts`, VS Code server extensions). Applying dotfiles to a shared home needs an explicit override flag that only the person passes.

Steps that need admin rights (system packages, Homebrew's first install, elevated winget) are never run automatically; Bootstrap prints the exact commands and continues.

## Mechanism

- chezmoi source state in this repo; one-line Bootstrap: `curl -fsSL https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.sh | sh` (Windows: `irm .../bootstrap.ps1 | iex`). The script installs chezmoi and uv, initialises, resolves the Version lock, applies, and runs Doctor.
- Machine-specific overrides in untracked `*.local` files (`config.local.fish`, `~/.gitconfig.local`, ...).
- Files that mix config with machine state are generated, never linked: `~/.claude.json` (MCP added via `claude mcp add`), `~/.codex/config.toml` (managed section; trust list, hook hashes and temp paths stay machine-local).
- No absolute home paths in any managed file; MCP commands are bare (`uvx`, `npx`, `graphify-mcp`, ...) and rely on `~/.local/bin` being first on PATH.
- Capture: symlink-free edits are pulled back with `chezmoi re-add`; non-file state (VS Code extension list, MCP list, plugin/marketplace list, uv tool list, micromamba env specs) is exported by a capture script into the repo for the person to review and commit.

## Versions

- Manifest tracks latest for every CLI, plugin, skill bundle and MCP server.
- Each install/update resolves latest once, writes that exact version into both Claude Code and Codex configuration, and records it in the Version lock for rollback.

## Components

- **Shell**: fish launched from `.bashrc` via the existing interactive-TTY `exec fish` guard (login shell cannot be changed on directory-service accounts). fisher plugins: fisher, z, sponge, autopair, fzf.fish, tide v6; tide settings captured. `vscode_remote_env.fish` kept for `VSCODE_IPC_HOOK_CLI` / remote-cli PATH refresh in tmux; its `GIT_ASKPASS` refresh is dropped once git uses SSH/gh.
- **CLI tools env** (`cli-tools`, conda-forge via micromamba on Linux; Homebrew on macOS; winget where applicable on Windows): fish, tmux (when the system lacks one), fzf, fd, bat, ripgrep, jq, gh, git-lfs. Optional `pdftools` env (poppler), installed by default. micromamba `base` left empty.
- **tmux**: current `~/.tmux.conf` (prefix C-a, mouse, 100k history, VS Code env pass-through).
- **Node**: fnm, default Node 22 LTS; old tarball Node and empty `~/.nvm` dropped.
- **uv**: standalone install; uv tools from the Manifest (semble[mcp], graphifyy[mcp], paper-search-mcp).
- **git**: identity, LFS filter, global ignore; gh installed; SSH key generated with `ssh-keygen -t ed25519`, public key printed with the link https://github.com/settings/ssh/new, Bootstrap waits and verifies with `ssh -T git@github.com`.
- **SSH**: committed public keys merged into `authorized_keys` (never overwriting existing lines); private keys never leave a machine. Desktop `~/.ssh/config` and WezTerm SSH domains generated from a Bitwarden item holding host aliases, addresses and usernames.
- **Claude Code**: native installer; user `CLAUDE.md` (timezone, semble, graphify, advisor, generic Agent orchestration section), `settings.json`, generic agents (deep-reasoner, worker, fast-worker, semble-search, researcher, codebase-memory set), plugins and marketplaces from the Manifest, own skills vendored, third-party skills reinstalled. codebase-memory-mcp kept, installed by its upstream installer which regenerates its hooks.
- **Status line**: existing Go program vendored; GitHub Actions publishes linux-amd64, darwin-arm64 and windows-amd64 binaries as releases; install downloads the matching one, building locally only when Go is present.
- **Codex**: standalone installer; `AGENTS.md`, generic agents (deep-reasoner, fast-worker), own skill `codex-queue-workflow` vendored, skill bundles reinstalled at Version-lock versions.
- **VS Code**: Desktop settings via VS Code Settings Sync; `remote.SSH.defaultExtensions` list kept in the repo (applied through Settings Sync) plus a fallback script using the server-side `code --install-extension`. JetBrainsMono Nerd Font installed on Desktops and set for the VS Code terminal.
- **WezTerm**: font, colour scheme, SSH domains; connecting to a Server attaches `tmux new -As wez` so sessions survive disconnects, separate from any VS Code tmux session.

## Secrets

Bitwarden Password Manager (free tier), folder `develop-env-settings`, one item per Secret (e.g. `paper-search` with IEEE key and Unpaywall email fields; `ssh-hosts`), read through chezmoi's Bitwarden template functions with the official `bw` CLI. Locked vault: Secret-bearing files are skipped with a warning, everything else applies; rerun after unlock. Claude Code and Codex logins are manual steps listed by Bootstrap and checked by Doctor.

## Agent-runnable

`AGENTS.md` (with `CLAUDE.md` symlink) gives an agent the Bootstrap order, the steps only the person can do (Bitwarden unlock, GitHub key upload, Claude/Codex login, admin-rights commands) and the done condition: Doctor reports every item PASS.

## Verification

GitHub Actions on every push: Ubuntu container as a non-admin user (full Server install + Doctor), macOS runner (Desktop + Server), Windows runner (Desktop). Bitwarden and login steps are skipped in CI.

## Delivery

Work in a clone at `~/develop-env-settings`, branch `init`, worker agents implement, PR with CI green on all three OSes, merge after the person approves. Every push and PR is confirmed with the person first. The repository is public (switched by the person on 2026-10-18).

## Not applied to the current lab Server

The current Server's home is a shared network mount used by every lab machine and long jobs are running; chezmoi is never applied there. Its existing configuration is read as the source for this repo only. Validation happens in CI and containers.
