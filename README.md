# develop-env-settings

One person's portable development environment: shell, terminal, editor-remote, language toolchains and agentic tools (Claude Code, Codex), installed by one Bootstrap on a new machine and checked by Doctor. Built on [chezmoi](https://www.chezmoi.io). Design: [docs/spec.md](docs/spec.md); vocabulary: [GLOSSARY.md](GLOSSARY.md); decisions: [docs/adr/](docs/adr/).

## Bootstrap

Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex
```

Bootstrap installs chezmoi and uv into `~/.local/bin`, resolves the Version lock, backs up what it will change, applies, and runs `bin/doctor`. It never uses admin rights; missing system packages are printed as commands.

### Roles

| Role | OS | Gets |
|---|---|---|
| `server` | Linux x86_64 | Full environment under userland paths |
| `desktop` | Windows, macOS | VS Code client pieces, WezTerm, git, gh, SSH client and key, Nerd Font, Bitwarden CLI, rtk, ccusage (Windows: only with a Node install), zotero-cli, Claude Code and Codex (same user files, plugins, skills, bundles, research add-ons and status line as a Server; MCP servers whose runtime is missing are skipped with a warning; on Windows drawio runs through `cmd /c npx` when Node exists, and Codex bundle skills are directory junctions) |
| `desktop+server` | macOS | Both, Server tools through Homebrew; zsh (`~/.zshrc` block) starts fish |

A Windows Server use goes through WSL2 with role `server`.

### Steps only you can do

- `bw login`, `export BW_SESSION=$(bw unlock --raw)`, `bw sync`, then apply again. The first apply on a new machine always skips Secret files.
- Zotero: create the Bitwarden item `zotero` (folder `develop-env-settings`) with custom fields `api_key` (a key from https://www.zotero.org/settings/keys with library and notes access; write access optional) and `library_id` (your user library ID, shown on that page); the next apply writes `~/.config/zotero-mcp/config.json`.
- Paste the printed SSH public key at https://github.com/settings/ssh/new.
- Log in with `claude` and `codex login` (every role).
- Run any admin-rights commands Bootstrap printed.

Done when `bin/doctor` reports no FAIL (WARN allowed), for example Claude or Codex bundle version drift or a missing status line.

### Existing homes

- Every file Bootstrap changes is first copied to `~/.dotfiles-backup-<timestamp>` (mode 700).
- A warning about NFS or long-running processes never blocks.
- On a umask 002 home, Bootstrap and the Claude and Codex install scripts remove group/other write permission from `~/.local` and `~/.local/bin` (only those two dirs), since the codebase-memory-mcp installer refuses them otherwise; Doctor's `local_bin_perms` check fails while they are writable.
- A system tmux older than 3.0 (RHEL/Rocky 8 ships 2.7) is shadowed by the `cli-tools` env tmux linked into `~/.local/bin`; a system tmux 3.0 or newer stays first.
- Apply never deletes old tools (previous micromamba envs, nvm, tarball Node); `bin/cleanup` does, after confirmation.
- Bootstrap never applies dotfiles on a hold home (one with `~/.config/develop-env/hold`); only the machine-local steps run.
- On a machine with a working environment, review `chezmoi diff` before the first apply.
- Agents must not run Bootstrap on a home that has a hold file, or on a shared home in use, without your go-ahead (see [AGENTS.md](AGENTS.md)).

Migration notes: Codex asks once to re-trust the codebase-memory hooks (now bare commands); `~/.local/bin/node` is re-pointed to fnm's default Node 24; the codebase-memory-mcp installer stops running `codebase-memory-mcp` processes when it upgrades. Codex asks once to trust the new rtk hook; remove a `~/.codex/hooks.json` left by a manual `rtk init -g --codex`, or Codex warns about two hook sources. A machine-local `[[hooks.PreToolUse]]` in `config.toml` is replaced by the managed one.

## Daily use

| Task | Command |
|---|---|
| Update everything to latest | `bin/update` (Windows: re-run the `irm ... \| iex` one-liner) |
| Pull machine changes back | `bin/capture` (prints `git diff --stat`; never commits, review and commit yourself) |
| Check the machine | `bin/doctor` (`--ci` skips login and Secret checks) |
| Remove old tools apply left behind | `bin/cleanup` |
| Token savings from rtk (Claude Code and Codex shell output is compressed by its hook) | `rtk gain` |
| Claude Code and Codex usage and cost from local logs (Asia/Taipei days) | `ccusage daily` |
| Roll back versions | `cd "$(chezmoi source-path)/.." && git checkout <rev> -- home/.chezmoidata/versions.yaml && chezmoi apply` |

`bin/capture` runs `chezmoi re-add`, rewrites `desktop/vscode/server-extensions.txt` from `~/.vscode-server/extensions`, and updates the membership of `claude.plugins`, `claude.marketplaces`, `uv_tools`, `cli_tools` and `pdftools` in `home/.chezmoidata/manifest.yaml`. It also compares the manifest `mcp` entries with the user-scope Claude MCP servers (names and commands only, from `~/.claude.json` `mcpServers` or `claude mcp list`) and prints the differences without rewriting them, since their args are templated. It never changes the Version lock.

### Research add-ons

| Add-on | Claude Code | Codex |
|---|---|---|
| ARIS ([wanshuiyin/Auto-claude-code-research-in-sleep](https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep), default-branch head, lock `codex-bundle-aris`) | plugin `aris@aris`; its `codex` reviewer MCP server is the bare `aris-codex-mcp` wrapper (starts `server.py` from the plugin's current cache dir, python3 3.9+ or uv's 3.12), and `~/.aris/repo` follows plugin updates | its Codex mirror `skills/skills-codex` as a skill bundle |
| Claude Scholar ([Galaxy-Dawn/claude-scholar](https://github.com/Galaxy-Dawn/claude-scholar), pinned at `d394fb599ed9`) | 40 allowlisted skills and 4 agents (`kaggle-miner`, `literature-reviewer`, `paper-miner`, `rebuttal-writer`); no hooks, commands or rules | none |
| Zotero (`zotero-mcp-server[scite]` uv tool: `zotero-cli`, `zotero-mcp`) | `zotero-cli` skill | `zotero-cli` skill in `~/.codex/skills` plus a pointer block in AGENTS.md |

Zotero is used from the shell, not as an MCP server; it reads `~/.config/zotero-mcp/config.json` (a Secret). To bump Claude Scholar, edit its line in `home/.chezmoidata/versions.yaml`: bin/update keeps a pinned value.

### Machine-local settings

Untracked `*.local` files hold what belongs to one machine: `~/.bashrc.local`, `~/.config/fish/config.local.fish`, `~/.gitconfig.local`. `~/.bashrc.local` is for environment that every bash needs, interactive or not: it is sourced right after the managed PATH block, before the non-interactive return, so scripts, `bash -c`, `bash -lc` and ssh commands see it (for example a hostname-gated `export DREAMPLACE_ROOT=...`). `config.local.fish` is likewise read by every fish. On RHEL-family hosts the managed `~/.bashrc` sources `/etc/bashrc` first, as the stock one does, so site settings (module, EDA setup) still load.

### Retrying installs

The install scripts never abort apply. When one fails (a download, an install, or a prerequisite such as Homebrew or fish not there yet) it warns, and Doctor prints the command to run: `bin/update`, or re-run Bootstrap (Windows: the `irm ... | iex` one-liner). A failed script writes a fresh nonce into its marker in `~/.local/state/develop-env/retry/` and shows that nonce in its `# retry:` line, so every apply after a failure reruns exactly those scripts, however many times in a row they fail; a clean run deletes the marker (the apply after it runs the script once more, harmlessly). The macOS scripts also watch for Homebrew. Apply never reruns a script that succeeded, so when something it installed is removed or broken later, Doctor's hint says to force every install script to run again:

```sh
chezmoi state delete-bucket --bucket=entryState    # run_onchange_ install scripts
chezmoi state delete-bucket --bucket=scriptState   # run_once_ scripts (prereqs, SSH key)
bin/update
```

## Tests

```sh
.tools/bin/bats tests/bats     # DEVENV_SKIP_DOCKER=1 skips the Docker tests
```

CI runs the same on Ubuntu, macOS and Windows, plus real Bootstraps: Server in a Docker container, `desktop+server` on a macOS runner and `desktop` on a Windows runner, each ending with `bin/doctor --ci` (or `bin/doctor.ps1 -Ci`) reporting no FAIL. Tests use sandbox HOMEs under `/tmp` and never touch the real home.

Changes go on a branch that is pushed (CI runs on every push) and merged into main with `git merge --no-ff` once every CI check is green; there are no pull requests (see [AGENTS.md](AGENTS.md)).
