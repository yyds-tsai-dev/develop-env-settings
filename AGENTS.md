# AGENTS.md: develop-env-settings

This repository builds the person's Personal environment on a new machine with one Bootstrap. Read [GLOSSARY.md](GLOSSARY.md) for the vocabulary and [docs/spec.md](docs/spec.md) for the design. If you are an agent asked to set up a machine, follow this file.

## Before you start

- Never run Bootstrap, `chezmoi apply`, `bin/update` or any installer on a home that has `~/.config/develop-env/hold`, or on a Server whose home is shared (NFS) and in use, without the person's explicit go-ahead. Ask first and say which home it is.
- On a machine that already has a working environment, run `chezmoi diff` and show it to the person before the first apply.
- No admin rights: never run `sudo`, `apt`, `dnf` or elevated `winget`. Print the commands Bootstrap lists for missing system packages and let the person run them.
- Never put a Secret (API key, password, host address) or an absolute home path in the repository.

## Bootstrap order

1. Run the one-liner for the OS. It installs chezmoi and uv into `~/.local/bin`, clones this repo, runs `chezmoi init`, resolves the Version lock, backs up what it will change, applies, runs `bin/machine-local` and finishes with `bin/doctor`.
   - Linux and macOS: `curl -fsSL https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.sh | sh`
   - Windows (PowerShell): `irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex`
   - Roles: `server` (Linux), `desktop` (Windows, macOS), `desktop+server` (macOS). A Windows Server use goes through WSL2 with role `server`.
2. Existing homes: every file Bootstrap changes is first copied to `~/.dotfiles-backup-<timestamp>` (mode 700). A warning about NFS or long-running processes never blocks. Apply never deletes old tools; `bin/cleanup` does, after confirmation. A hold file makes Bootstrap run only the machine-local steps (SSH key, `known_hosts`).
3. Do the person-only steps below, then re-apply: `bin/update` on Linux and macOS (it retries failed installs too), re-run the `irm ... | iex` one-liner on Windows.
4. Run `bin/doctor`.

## Steps only the person can do

Stop and ask; do not attempt these yourself.

- Bitwarden: `bw login`, then `export BW_SESSION=$(bw unlock --raw)`, then `bw sync`, then apply again. The first apply on a new machine always skips the Secret files because `bw` is installed only during that apply.
- GitHub SSH key: paste the public key Bootstrap printed at https://github.com/settings/ssh/new.
- Log in to Claude Code (`claude`) and Codex (`codex login`) on server roles (a plain Desktop gets neither).
- Any admin-rights commands Bootstrap printed (system packages, Homebrew's first install, elevated winget).

## Done

Done when `bin/doctor` reports no FAIL (WARN allowed), for example Claude or Codex bundle version drift or a missing status line. Report the remaining person-only steps and every WARN to the person. A FAIL hint names the command to run (`bin/update`, or re-run Bootstrap; `chezmoi state delete-bucket --bucket=entryState && bin/update` when the install script succeeded earlier and must be forced to rerun).

## Migration notes for existing machines

- Codex asks once to re-trust the codebase-memory hooks, which are now bare commands.
- `~/.local/bin/node` is re-pointed to fnm's default Node 24.
- The codebase-memory-mcp installer stops running `codebase-memory-mcp` processes when it upgrades.

## Maintaining the repo

- Update: `bin/update` (resets the local Version lock, pulls, runs Bootstrap again). Windows: re-run the `irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex` one-liner.
- Capture: `bin/capture` pulls machine changes back (`chezmoi re-add`, VS Code server extensions, manifest membership). It prints `git diff --stat` and never commits; review and commit yourself.
- Rollback: `cd "$(chezmoi source-path)/.." && git checkout <rev> -- home/.chezmoidata/versions.yaml && chezmoi apply`.
- Retrying installs: a failed install script leaves a retry marker with a fresh nonce in `~/.local/state/develop-env/retry/`, so every `bin/update` (Windows: the one-liner) reruns it until it succeeds. To rerun scripts that succeeded earlier (something they installed was removed later): `chezmoi state delete-bucket --bucket=entryState` (run_onchange_ scripts; `--bucket=scriptState` for run_once_), then `bin/update`.
- Tests: `.tools/bin/bats tests/bats` (set `DEVENV_SKIP_DOCKER=1` to skip the Docker tests) and `uv run --with pytest --with pyyaml --with httpx --with tomlkit pytest tests/py`. Tests use sandbox HOMEs under `/tmp`, never the real home.
- Commit messages are in English. Push and open PRs only after the person agrees.
