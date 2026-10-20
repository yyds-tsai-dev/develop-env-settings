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
| `desktop` | Windows, macOS | VS Code client pieces, WezTerm, git, gh, SSH client and key, Nerd Font, Bitwarden CLI |
| `desktop+server` | macOS | Both |

A Windows Server use goes through WSL2 with role `server`.

### Steps only you can do

- `bw login`, `export BW_SESSION=$(bw unlock --raw)`, `bw sync`, then apply again. The first apply on a new machine always skips Secret files.
- Paste the printed SSH public key at https://github.com/settings/ssh/new.
- Log in with `claude` and `codex login`.
- Run any admin-rights commands Bootstrap printed.

Done when `bin/doctor` reports no FAIL (WARN is allowed, for example Claude or Codex bundle version drift).

### Existing homes

- Every file Bootstrap changes is first copied to `~/.dotfiles-backup-<timestamp>` (mode 700).
- A warning about NFS or long-running processes never blocks.
- Apply never deletes old tools (previous micromamba envs, nvm, tarball Node); `bin/cleanup` does, after confirmation.
- A home with `~/.config/develop-env/hold` never gets dotfiles applied; only the machine-local steps run.
- On a machine with a working environment, review `chezmoi diff` before the first apply.
- Agents must not run Bootstrap on a home that has a hold file, or on a shared home in use, without your go-ahead (see [AGENTS.md](AGENTS.md)).

Migration notes: Codex asks once to re-trust the codebase-memory hooks (now bare commands); `~/.local/bin/node` is re-pointed to fnm's default Node 24; the codebase-memory-mcp installer stops running `codebase-memory-mcp` processes when it upgrades.

## Daily use

| Task | Command |
|---|---|
| Update everything to latest | `bin/update` |
| Pull machine changes back | `bin/capture` (prints `git diff --stat`; never commits, review and commit yourself) |
| Check the machine | `bin/doctor` (`--ci` skips login and Secret checks) |
| Remove old tools apply left behind | `bin/cleanup` |
| Roll back versions | `git checkout <rev> -- home/.chezmoidata/versions.yaml && chezmoi apply` |

`bin/capture` runs `chezmoi re-add`, rewrites `desktop/vscode/server-extensions.txt` from `~/.vscode-server/extensions`, and updates the membership of `claude.plugins`, `claude.marketplaces`, `uv_tools`, `cli_tools` and `pdftools` in `home/.chezmoidata/manifest.yaml`. It never changes the Version lock.

## Tests

```sh
.tools/bin/bats tests/bats     # DEVENV_SKIP_DOCKER=1 skips the Docker tests
```

CI runs the same on Ubuntu, macOS and Windows. Tests use sandbox HOMEs under `/tmp` and never touch the real home.
