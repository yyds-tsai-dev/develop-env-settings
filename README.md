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
| `desktop` | Windows, macOS | VS Code client pieces, WezTerm, git, gh, SSH client and key, Nerd Font, Bitwarden CLI (no Claude Code, Codex or other agent tooling) |
| `desktop+server` | macOS | Both, Server tools through Homebrew; zsh (`~/.zshrc` block) starts fish |

A Windows Server use goes through WSL2 with role `server`.

### Steps only you can do

- `bw login`, `export BW_SESSION=$(bw unlock --raw)`, `bw sync`, then apply again. The first apply on a new machine always skips Secret files.
- Paste the printed SSH public key at https://github.com/settings/ssh/new.
- Log in with `claude` and `codex login` (server roles).
- Run any admin-rights commands Bootstrap printed.

Done when `bin/doctor` reports no FAIL (WARN allowed), for example Claude or Codex bundle version drift or a missing status line.

### Existing homes

- Every file Bootstrap changes is first copied to `~/.dotfiles-backup-<timestamp>` (mode 700).
- A warning about NFS or long-running processes never blocks.
- Apply never deletes old tools (previous micromamba envs, nvm, tarball Node); `bin/cleanup` does, after confirmation.
- Bootstrap never applies dotfiles on a hold home (one with `~/.config/develop-env/hold`); only the machine-local steps run.
- On a machine with a working environment, review `chezmoi diff` before the first apply.
- Agents must not run Bootstrap on a home that has a hold file, or on a shared home in use, without your go-ahead (see [AGENTS.md](AGENTS.md)).

Migration notes: Codex asks once to re-trust the codebase-memory hooks (now bare commands); `~/.local/bin/node` is re-pointed to fnm's default Node 24; the codebase-memory-mcp installer stops running `codebase-memory-mcp` processes when it upgrades.

## Daily use

| Task | Command |
|---|---|
| Update everything to latest | `bin/update` (Windows: re-run the `irm ... \| iex` one-liner) |
| Pull machine changes back | `bin/capture` (prints `git diff --stat`; never commits, review and commit yourself) |
| Check the machine | `bin/doctor` (`--ci` skips login and Secret checks) |
| Remove old tools apply left behind | `bin/cleanup` |
| Roll back versions | `cd "$(chezmoi source-path)/.." && git checkout <rev> -- home/.chezmoidata/versions.yaml && chezmoi apply` |

`bin/capture` runs `chezmoi re-add`, rewrites `desktop/vscode/server-extensions.txt` from `~/.vscode-server/extensions`, and updates the membership of `claude.plugins`, `claude.marketplaces`, `uv_tools`, `cli_tools` and `pdftools` in `home/.chezmoidata/manifest.yaml`. It also compares the manifest `mcp` entries with the user-scope Claude MCP servers (names and commands only, from `~/.claude.json` `mcpServers` or `claude mcp list`) and prints the differences without rewriting them, since their args are templated. It never changes the Version lock.

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
