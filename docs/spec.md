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
| Desktop | Windows, macOS | VS Code client pieces, WezTerm, git, gh, SSH client + key, Nerd Font, Bitwarden CLI, Claude Code (same user CLAUDE.md, settings, generic agents, plugins, skills and status line as a Server) |
| Desktop + Server | macOS (opt-in) | Both, Server tools via Homebrew |
| Server via WSL2 | Windows | Treated as a Linux Server |

Codex stays Server-only: a plain Desktop gets no Codex, `~/.codex` or Codex MCP configuration (revised 2026-10-21; Claude Code was Server-only before). Claude Code on a plain Desktop registers only the MCP servers whose command exists there (semble needs `uvx`, which Bootstrap installs everywhere; drawio needs `npx`, present on macOS through fnm and skipped on Windows; codebase-memory-mcp comes from its upstream installer on macOS and Windows) and skips the graphify skill (the graphifyy uv tool is Server-only); each skip prints one warning and is not a failure, and Doctor expects only what was registerable.

Existing homes: the intended use is a new machine where nothing runs yet, so Bootstrap applies by default, including on a home mounted from network storage (NFS), which only the same account's machines see. Before applying it always backs up every file it will change to `~/.dotfiles-backup-<timestamp>`, and when the home is on NFS or the account has processes running longer than 10 minutes (other than shells, tmux, sshd, the VS Code server, Claude Code, Codex and Bootstrap itself) it prints a warning listing them, then continues. Apply only adds and replaces; it never deletes old tools (previous micromamba envs, nvm, tarball Node) — `bin/cleanup` removes those when the person runs it. A home containing `~/.config/develop-env/hold` never gets dotfiles applied; Bootstrap then runs only the machine-local steps (SSH key, `known_hosts`, VS Code server extensions). On a machine whose home already has a working environment, the person reviews `chezmoi diff` before the first apply.

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

- **Shell**: fish launched from `.bashrc` via the existing interactive-TTY `exec fish` guard (login shell cannot be changed on directory-service accounts). Where the login shell is tcsh, a managed block appended at the end of `~/.tcshrc` (or `~/.cshrc` when only that exists) does the same; the rest of that file, such as EDA tool setup, is never touched. fisher plugins: fisher, z, sponge, autopair, fzf.fish, tide v6; tide settings captured. `vscode_remote_env.fish` kept for `VSCODE_IPC_HOOK_CLI` / remote-cli PATH refresh in tmux; its `GIT_ASKPASS` refresh is dropped once git uses SSH/gh.
- **CLI tools env** (`cli-tools`, conda-forge via micromamba on Linux; Homebrew on macOS; winget where applicable on Windows): fish, tmux (when the system lacks one), fzf, fd, bat, ripgrep, jq, gh, git-lfs. Optional `pdftools` env (poppler), installed by default. micromamba `base` left empty.
- **tmux**: current `~/.tmux.conf` (prefix C-a, mouse, 100k history, VS Code env pass-through).
- **Node**: fnm, default Node 24 LTS; old tarball Node and `~/.nvm` are left in place by apply and removed by `bin/cleanup`.
- **uv**: standalone install; uv tools from the Manifest (semble[mcp], graphifyy[mcp], paper-search-mcp).
- **git**: identity, LFS filter, global ignore; gh installed; SSH key generated with `ssh-keygen -t ed25519`, public key printed with the link https://github.com/settings/ssh/new, Bootstrap waits and verifies with `ssh -T git@github.com`.
- **SSH**: committed public keys merged into `authorized_keys` (never overwriting existing lines); private keys never leave a machine. Desktop `~/.ssh/config` and WezTerm SSH domains generated from a Bitwarden item holding host aliases, addresses and usernames.
- **Claude Code**: native installer; user `CLAUDE.md` (timezone, semble, graphify, advisor, generic Agent orchestration section), `settings.json`, generic agents (deep-reasoner, worker, fast-worker, semble-search, researcher, codebase-memory set), plugins and marketplaces from the Manifest, own skills vendored, third-party skills reinstalled. codebase-memory-mcp kept, installed by its upstream installer which regenerates its hooks (`install.sh --clients=claude` on Linux and macOS; on Windows `install.ps1 --skip-config`, then `codebase-memory-mcp install --clients=claude`, whose hooks are `.cmd` shims run through `cmd.exe`). Every role gets it; Windows through `run_onchange_after_50-claude.ps1`.
- **Status line**: existing Go program vendored; GitHub Actions publishes linux-amd64, darwin-arm64 and windows-amd64 binaries as releases; install downloads the matching one, building locally only when Go is present.
- **Codex**: standalone installer; `AGENTS.md`, generic agents (deep-reasoner, fast-worker), own skill `codex-queue-workflow` vendored, skill bundles reinstalled at Version-lock versions. Its MCP servers include one remote server, `openaiDeveloperDocs` (`url = "https://developers.openai.com/mcp"`, `tool_timeout_sec = 60`), declared in the Manifest with a `url` instead of a command; Claude Code does not get it.
- **VS Code**: Desktop settings via VS Code Settings Sync; `remote.SSH.defaultExtensions` list kept in the repo (applied through Settings Sync) plus a fallback script using the server-side `code --install-extension`. JetBrainsMono Nerd Font installed on Desktops and set for the VS Code terminal.
- **WezTerm**: font, colour scheme, SSH domains; connecting to a Server attaches `tmux new -As wez` so sessions survive disconnects, separate from any VS Code tmux session.

## Secrets

Bitwarden Password Manager (free tier), folder `develop-env-settings`, one item per Secret, read with the official `bw` CLI through the shared `bw-field` template (it calls `bw status` and `bw list` only when `bw` is on PATH and the vault is `unlocked`, so it never prompts or hangs). Locked, missing, failing or incomplete: Secret-bearing targets are listed in `home/.chezmoiignore` behind the `bw-ready` guard, which calls `warnf "Bitwarden locked or missing: skipping <file>"` once per target. Ignored targets are left untouched (an existing file is never removed by an empty render); everything else applies; rerun after unlock.

Items:

- `paper-search`: custom fields `ieee_api_key` and `unpaywall_email`. Rendered to `~/.config/paper-search-mcp/.env` (mode 600) as `PAPER_SEARCH_MCP_IEEE_API_KEY` and `PAPER_SEARCH_MCP_UNPAYWALL_EMAIL`.
- `ssh-hosts`: the note is JSON, a list of `{alias, hostname, user, port}`.

`bw` is installed by an `after` script (`25-bw`) that needs Node: `npm install -g @bitwarden/cli@<locked version>` through fnm's Node on Linux and macOS, the official release zip into the user's bin dir on Windows. Consequence: on the very first apply on a new machine `bw` is not installed yet when templates render, so Secret files are skipped with a warning; the person then runs `bw login`, `export BW_SESSION=$(bw unlock --raw)`, `bw sync` and applies again. Claude Code and Codex logins are manual steps listed by Bootstrap and checked by Doctor.

## Agent-runnable

`AGENTS.md` (with `CLAUDE.md` symlink) gives an agent the Bootstrap order, the steps only the person can do (Bitwarden unlock, GitHub key upload, Claude/Codex login, admin-rights commands) and the done condition: Doctor reports no FAIL (WARN allowed).

## Verification

GitHub Actions on every push: Ubuntu container as a non-admin user (full Server install + Doctor), macOS runner (Desktop, and Desktop + Server), Windows runner (Desktop, including the Claude Code checks); each Bootstrap must end with Doctor reporting no FAIL (WARN allowed). Bitwarden and login steps are skipped in CI.

## Delivery

Work in a clone at `~/develop-env-settings`, branch `init`, worker agents implement, PR with CI green on all three OSes, merge after the person approves. Every push and PR is confirmed with the person first. The repository is public (switched by the person on 2026-10-18).

## Not applied to the current lab Server

The current Server's home is a shared network mount used by every lab machine and long jobs are running; chezmoi is never applied there. Its existing configuration is read as the source for this repo only. Validation happens in CI and containers.
