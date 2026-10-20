# develop-env-settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A chezmoi repository that turns a fresh Linux Server or Windows/macOS Desktop into the person's Personal environment with one Bootstrap command, verified by Doctor.

**Architecture:** chezmoi source state lives under `home/` (`.chezmoiroot`). Role, shared-home and CI flags are computed once in `home/.chezmoi.toml.tmpl`. What to install is declared in `home/.chezmoidata/manifest.yaml`; the exact versions are in `home/.chezmoidata/versions.yaml` (the Version lock), written by a resolver that Bootstrap runs before `chezmoi apply`. Installs run from `home/.chezmoiscripts/`, and files that mix config with machine state are merged by `modify_` scripts that call small Python helpers in `lib/`. Doctor (`bin/doctor`, `bin/doctor.ps1`) is a set of per-component check files that every task extends.

**Tech Stack:** chezmoi (latest), bash, PowerShell 7, Python 3.12+ single-file scripts run by `uv run --script` (PEP 723), pytest (helpers), bats-core (render and integration tests), Docker `ubuntu:22.04` (local Server test), GitHub Actions (ubuntu, macos, windows), Go (status line, existing code).

**Spec:** [docs/spec.md](../../spec.md), vocabulary in [GLOSSARY.md](../../../GLOSSARY.md), decisions in [docs/adr/](../../adr/).

## Global Constraints

- **Never apply to the lab Server.** On the machine where this plan is executed (home `/ldaphome/yyds-tsai-dev`, a shared NAS mount), never run `chezmoi apply`, `bootstrap.sh`, or any install script against the real `$HOME`. Render tests use `--destination`, `--config`, `--cache` and `--persistent-state` under `mktemp -d` on `/tmp`. Anything that runs an installer runs inside Docker (`docker` works without sudo here) or in GitHub Actions.
- **Source material:** read the live configuration on this Server (`~/.tmux.conf`, `~/.config/fish/`, `~/.gitconfig`, `~/.config/git/ignore`, `~/.condarc`, `~/.bashrc`, `~/.claude/{CLAUDE.md,settings.json,agents,skills,statusline}`, `~/.codex/{AGENTS.md,config.toml,agents,skills,skill-bundles}`, `~/.ssh/authorized_keys`, `~/.vscode-server/extensions`, and the project's `CLAUDE.md`, `.claude/agents/`, `.codex/agents/` in `/ldaphome/yyds-tsai-dev/IO-Aware-Top-Level-Placer`), and copy it in. Never modify those files.
- **No secrets in git.** No API key, email used as an API identity, host IP address, SSH username for another host, password, or auth file is committed. `~/.config/ioplace/nvl4.pw` is out of scope.
- **No absolute home paths.** No managed file contains `/ldaphome` or `/home/<user>`. Use `{{ .chezmoi.homeDir }}`, `$HOME`, `~`, or a bare command on PATH. A repo-wide test enforces this (Task 1).
- **No admin rights.** No script calls `sudo`, `apt`, `dnf`, or elevated `winget`. Missing system prerequisites are printed as commands for the person to run, and the script continues.
- **Linux Server:** x86_64. All installs go to `~/.local/bin`, `~/.local/share`, `~/micromamba` (`MAMBA_ROOT_PREFIX`), and fnm's default dir. `~/.local/bin` comes first on PATH in bash and fish.
- **Roles:** `server` (Linux), `desktop` (Windows, macOS), `desktop+server` (macOS only). Windows Server use goes through WSL2 with role `server`.
- **Versions:** every manifest entry tracks latest. Each Bootstrap or `bin/update` resolves once, then writes the same exact version into the Claude Code and Codex configuration and into `versions.yaml`.
- **Bitwarden:** the folder is `develop-env-settings` and the CLI is `bw`. A file that needs a Secret renders empty when `bw` is missing or locked, so chezmoi does not create it, and the template calls `warnf`.
- **Docs and commits** are in English. Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_014DNfNamdWDVDvkwPck2oyK
  ```
- **Local disk for execution:** the NAS home is slow (open() 0.2–0.35 s). Work in a clone at `/tmp/devenv-work/develop-env-settings` (local disk) whose remote `nas` is `~/develop-env-settings`; set `UV_CACHE_DIR=/tmp/devenv-work/uv-cache`; Docker bind mounts come from `/tmp/devenv-work`. Push commits back to `nas` at each task boundary.
- **Git:** all work is on branch `init`. Commit at each task boundary. Never push and never open a PR; the scheduler does both after asking the person.

## Review Focus

1. **Running Bootstrap twice:** the second run changes nothing. No duplicate `authorized_keys` line, PATH entry, MCP registration or plugin, and no new SSH key. Tested in Task 4 (Docker double run) and Task 5 (merge idempotence).
2. **A Server whose home already holds a different, unmanaged `~/.bashrc`, `~/.config/fish` or `~/.codex/config.toml`:** chezmoi replaces the managed files, but machine-local Codex sections (`[projects.*]`, `hooks.state`) and every existing `authorized_keys` line survive. Tested in Tasks 5 and 8.
3. **Bitwarden absent or locked:** apply still succeeds, prints one warning per skipped file, and leaves no empty or partial `.env` or `~/.ssh/config`. Tested in Task 6.
4. **Shared home:** on a home mounted over NFS, Bootstrap never runs `chezmoi apply` (that would rewrite every machine on the mount); it runs only `bin/machine-local` (SSH key, `known_hosts`, VS Code server extensions) unless the person passes `--apply-shared-home` by hand. Tested in Task 4.
5. **No network to one upstream** (PyPI, npm or GitHub down) during resolve: the resolver keeps the previous lock value for that entry, warns, and exits 0. It does not write an empty version. Tested in Task 3.
6. **Fresh-machine lock drift:** the resolver dirties `versions.yaml` in the chezmoi source clone; a later `bin/update` must not fail on a pull conflict over that file. Tested in Task 4.

---

## File Structure

```
.chezmoiroot                         "home"
bootstrap.sh / bootstrap.ps1         install chezmoi+uv to ~/.local/bin, init, resolve, apply
bin/update  bin/doctor  bin/doctor.ps1  bin/capture
lib/resolve_versions.py              Manifest -> Version lock
lib/merge_authorized_keys.py         modify_ helper
lib/merge_codex_config.py            modify_ helper
doctor.d/NN-<component>.sh           check functions per component (+ .ps1 twins where Windows applies)
home/.chezmoi.toml.tmpl              role / sharedHome / ci data
home/.chezmoiignore                  role- and OS-based ignores
home/.chezmoidata/manifest.yaml      what to install
home/.chezmoidata/versions.yaml      Version lock
home/.chezmoiscripts/                run_* install scripts (.sh.tmpl, .ps1.tmpl)
home/dot_*, home/private_dot_*       managed files
statusline/                          Go source (moved from ~/.claude/statusline)
desktop/vscode/                      settings snippet for Settings Sync, extensions list
tests/bats/*.bats  tests/py/test_*.py  tests/docker/Dockerfile.server  tests/setup-tools.sh
.github/workflows/ci.yml  .github/workflows/statusline-release.yml
AGENTS.md  CLAUDE.md -> AGENTS.md  README.md
```

### Shared interfaces

- **chezmoi data** (from `.chezmoi.toml.tmpl`):
  - `.role`: one of `"server"`, `"desktop"`, `"desktop+server"`. Set by `promptChoiceOnce`; CI sets it with `--promptChoice role=...`.
  - `.isServer`, `.isDesktop`: bool.
  - `.sharedHome`: bool.
  - `.ci`: bool, true when env `CI=true`.
- **Shared-home rule:**
  - Linux only.
  - `.sharedHome` is true when `stat -f -c %T $HOME` is `nfs` or `nfs4` (filesystem type alone; no marker file).
- **Manifest** (`manifest.yaml`). Every entry has `name` (the lock key), `source` (`pypi:<pkg>`, `npm:<pkg>`, `github:<owner>/<repo>`, `conda-forge:<pkg>`, or `none`), and optional `platforms` (subset of `linux`, `darwin`, `windows`). Top-level keys:
  - `cli_tools`: list. Linux: micromamba env `cli-tools`. macOS: brew. Windows: winget id via `winget:` field.
  - `pdftools`: list.
  - `uv_tools`: list with `spec` (e.g. `"semble[mcp]"`).
  - `node`: `{ major: 22 }`.
  - `mcp`: list with `command`, `args` (may contain `{version}`), and `clients: [claude, codex]`.
  - `claude.marketplaces`: list of `{name, source}`.
  - `claude.plugins`: list of `{name, marketplace}`.
  - `codex.skill_bundles`: list of `{name, source}`.
  - `installers`: list for claude, codex, codebase-memory-mcp, fnm, micromamba, chezmoi, bw, statusline.
- **Version lock** (`versions.yaml`): `versions: { <name>: "<exact version>" }`, plus `resolved_at: "<ISO 8601 UTC>"`. Templates read it as `index .versions "<name>"`.
- **Doctor protocol:**
  - Each `doctor.d/*.sh` defines functions named `check_*` and calls `register check_name`.
  - `bin/doctor [--ci]` runs them all and prints one line per check: `PASS <name>`, `FAIL <name>: <reason>`, or `SKIP <name>: <reason>`.
  - Exit status is 1 if any check FAILs. `--ci` turns login and Secret checks into SKIP.
  - `bin/doctor.ps1` follows the same protocol with `doctor.d/*.ps1`.

---

### Task 1: Scaffold, role data, render harness, path guard

**Files:**
- Create: `.chezmoiroot`, `.gitignore` (`.tools/`), `home/.chezmoi.toml.tmpl`, `home/.chezmoiignore`, `home/.chezmoidata/manifest.yaml` (keys from the interface above, initially empty lists), `home/.chezmoidata/versions.yaml`, `bin/doctor`, `bin/doctor.ps1`, `doctor.d/00-core.sh`, `tests/setup-tools.sh`, `tests/bats/helpers.bash`, `tests/bats/scaffold.bats`, `.github/workflows/ci.yml`

**Interfaces:**
- Produces: the data keys, the doctor protocol, and `render_home ROLE OS` in `helpers.bash`. `render_home` runs `chezmoi apply` (no scripts: `--exclude scripts`) into a temp destination with an isolated config built by `chezmoi init --promptChoice role=ROLE`, and echoes that destination.
- `tests/setup-tools.sh` downloads chezmoi and bats-core into `.tools/` and never touches `~`.

- [ ] **Step 1:** Write `scaffold.bats`:
  - `@test "role server sets isServer"` asserts `chezmoi execute-template '{{ .isServer }}'` prints `true`.
  - `@test "role desktop on linux is rejected"`: config init fails with a message containing `desktop role needs windows or darwin`.
  - `@test "role desktop+server off darwin is rejected"`: message contains `desktop+server role needs darwin`.
  - `@test "no managed file contains an absolute home path"`: `grep -rE '/ldaphome|/home/[a-z]' home/ lib/ bin/ doctor.d/` finds nothing.
  - `@test "doctor exits 0 with only core checks"`.
- [ ] **Step 2:** Run `tests/setup-tools.sh && .tools/bin/bats tests/bats/scaffold.bats`. Expected: FAIL.
- [ ] **Step 3:** Implement the files.
  - `.chezmoiignore` ignores Server-only paths unless `.isServer`, and Desktop-only paths unless `.isDesktop`.
  - The CI workflow runs `tests/setup-tools.sh`, bats and pytest on `ubuntu-latest`, `macos-latest` and `windows-latest` (Windows: bats via Git Bash for render tests only).
- [ ] **Step 4:** Run the bats file again. Expected: PASS.
- [ ] **Step 5:** Commit `feat: chezmoi scaffold, role data, doctor skeleton, render harness`.

### Task 2: Shell, tmux, git dotfiles (Server)

**Files:**
- Create:
  - `home/dot_bashrc.tmpl`: Ubuntu default body plus a managed block.
    - PATH: `~/.local/bin` first, added once.
    - `micromamba shell hook` with `MAMBA_ROOT_PREFIX={{ .chezmoi.homeDir }}/micromamba`.
    - `fnm env`.
    - The existing interactive-TTY `exec fish` guard, moved to the end so PATH, micromamba and fnm are already set before fish starts.
    - `[ -f ~/.bashrc.local ] && . ~/.bashrc.local`.
  - `home/dot_tmux.conf`: copied verbatim from `~/.tmux.conf`.
  - `home/dot_gitconfig.tmpl`: user name, user email, LFS filter, `[include] path = ~/.gitconfig.local`.
  - `home/dot_config/git/ignore`.
  - `home/dot_condarc`.
  - `home/dot_config/fish/config.fish`: sources `config.local.fish` if present.
  - `home/dot_config/fish/fish_plugins`: current list plus nothing else.
  - `home/dot_config/fish/conf.d/10-env.fish.tmpl`: PATH, `micromamba shell hook -s fish`, `fnm env --use-on-cd --shell fish`.
  - `home/dot_config/fish/conf.d/vscode_remote_env.fish`: copy of the current file with the `GIT_ASKPASS` refresh removed and the `VSCODE_IPC_HOOK_CLI` / remote-cli PATH refresh kept.
  - `home/.chezmoiscripts/run_onchange_after_20-fish-plugins.sh.tmpl`: installs fisher if missing, runs `fisher update`, then `tide configure --auto` with the flags that reproduce the current `tide_*` universal variables in `~/.config/fish/fish_variables`.
  - `doctor.d/20-shell.sh`.
  - `tests/bats/shell.bats`.

**Interfaces:**
- Consumes: `render_home` (Task 1).
- Produces: the managed PATH order, used by Tasks 4, 7 and 8.

- [ ] **Step 1:** Write `shell.bats`:
  - `@test "rendered bashrc puts ~/.local/bin first exactly once"`.
  - `@test "rendered fish files parse"`: `fish --no-execute` on each rendered `.fish` file. Skip if fish is absent.
  - `@test "tmux conf loads"`: `tmux -L t -f <rendered> start-server \; kill-server` exits 0.
  - `@test "vscode_remote_env.fish no longer sets GIT_ASKPASS"`.
  - `@test "gitconfig includes ~/.gitconfig.local"`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement the files. Doctor checks: `fish` on PATH, `fisher list` contains `ilancosman/tide`, `tmux -V` ≥ 3.0, `git config user.email` is non-empty.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit `feat: managed bash, fish, tmux and git config`.

### Task 3: Manifest and Version lock resolver

**Files:**
- Create: `lib/resolve_versions.py`, `tests/py/test_resolve_versions.py`, `tests/py/fixtures/`.
- Modify: `home/.chezmoidata/manifest.yaml`. Fill in every entry the spec names: cli-tools, pdftools, uv tools, node, the MCP servers semble / codebase-memory-mcp / drawio / graphify / paper-search, the current marketplaces and plugins, the Codex skill bundles, and the installers.

**Interfaces:**
- Produces: CLI `uv run --script lib/resolve_versions.py --manifest PATH --lock PATH [--only NAME ...] [--offline]`.
  - Writes the lock in place with sorted keys.
  - The core function is `resolve(manifest: dict, old_lock: dict, fetch: Callable[[str], str | None]) -> tuple[dict, list[str]]`. It returns the new lock and a list of warnings.
  - `fetch(source)` returns the latest version, or `None` on any network or parse failure.
  - Upstream endpoints:
    - PyPI JSON `info.version`
    - npm registry `dist-tags.latest`
    - GitHub `releases/latest` `tag_name`, with any leading `v` stripped
    - conda-forge: anaconda.org API `latest_version`
  - `source: none` entries are not resolved.

- [ ] **Step 1:** Write the tests:
  - `test_resolves_each_source_kind`: a fake `fetch` returns `"1.2.3"` and every non-`none` entry gets `"1.2.3"`.
  - `test_failed_fetch_keeps_previous_value_and_warns`: old lock `{"semble": "0.5.5"}`, `fetch` returns `None`, so the new value is `"0.5.5"` and one warning mentions `semble`.
  - `test_failed_fetch_without_previous_value_omits_key_and_warns`.
  - `test_github_tag_v_prefix_stripped`.
  - `test_only_limits_resolution`.
  - `test_lock_written_with_resolved_at_utc`.
- [ ] **Step 2:** Run `uv run --with pytest --with pyyaml pytest tests/py/test_resolve_versions.py -v`. Expected: FAIL.
- [ ] **Step 3:** Implement. Declare the PEP 723 dependencies `pyyaml` and `httpx`. Each fetch has a 10 s timeout.
- [ ] **Step 4:** Run it again. Expected: PASS. Then run the resolver once for real, inside Docker or on the host (it only does network reads and writes the repo file), and commit the resulting lock.
- [ ] **Step 5:** Commit `feat: manifest and version lock resolver`.

### Task 4: Bootstrap and the Linux Server tool layer

**Files:**
- Create:
  - `bootstrap.sh`
  - `bin/update`
  - `home/.chezmoiscripts/run_once_before_00-prereqs.sh.tmpl`: lists missing `curl`, `git`, `tar`, `bzip2` as `sudo apt install ...` text and exits 0.
  - `run_onchange_after_10-micromamba-envs.sh.tmpl`: `cli-tools` and `pdftools` envs from the manifest at their locked versions. Skipped when `.sharedHome`.
  - `run_onchange_after_15-symlinks.sh.tmpl`: `~/.local/bin` links into the `cli-tools` and `pdftools` env `bin/`.
  - `run_onchange_after_20-node.sh.tmpl`: installs fnm, then `fnm install {node.major}` and `fnm default`.
  - `run_onchange_after_30-uv-tools.sh.tmpl`.
  - `bin/machine-local`: SSH key step (Task 5 script), `known_hosts` for github.com, VS Code server extensions fallback (Task 10); idempotent.
  - `doctor.d/10-tools.sh`.
  - `tests/docker/Dockerfile.server`: `ubuntu:22.04`, curl, git and ca-certificates added at image build, then a non-root user `dev` with no sudo.
  - `tests/bats/bootstrap.bats`.

**Interfaces:**
- Consumes: the lock (Task 3), PATH order (Task 2).
- Produces: `bootstrap.sh [--source DIR] [--role ROLE] [--ci]`.
  1. Install chezmoi and uv into `~/.local/bin` if missing.
  2. `chezmoi init` from `--source` (default `yyds-tsai-dev/develop-env-settings`).
  3. Resolve the lock.
  4. `chezmoi apply`.
  5. Run `bin/doctor`.

  `bin/update` first runs `git -C <source> checkout -- home/.chezmoidata/versions.yaml`, then `chezmoi update`, resolve, apply and doctor.
  When `.sharedHome` is true, `bootstrap.sh` and `bin/update` skip `chezmoi apply`, print `shared home: not applying dotfiles (pass --apply-shared-home to override)`, and run only `bin/machine-local`. `--apply-shared-home` is person-only and named so in AGENTS.md.
- One-line Bootstrap (README):

  ```
  curl -fsSL https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.sh | sh
  ```

  This replaces the bare chezmoi one-liner in the spec, so the resolve step runs between init and apply. `docs/spec.md` already says so.

- [ ] **Step 1:** Write `bootstrap.bats`. Each test runs `docker run` on the image with the repo mounted read-only and `--source /repo --role server --ci`.
  - `@test "server bootstrap in container ends with doctor PASS"`.
  - `@test "second bootstrap changes nothing"`: `chezmoi diff` is empty, the PATH line count in `.bashrc` is unchanged, and `micromamba env list` has the same lines.
  - `@test "shared home: no managed dotfile written"`: with `DEVENV_FAKE_FSTYPE=nfs4`, after bootstrap `$HOME/.bashrc` is byte-identical to the image's original, `~/.config/fish/fish_plugins` does not exist, and the log contains `shared home: not applying dotfiles`.
  - `@test "update after a dirty lock does not conflict"`: bootstrap, modify the lock in the source clone, advance the upstream fixture repo's lock, run `bin/update`; it exits 0.
  - `@test "missing bzip2 is printed as a command, not run"`.
- [ ] **Step 2:** Run `.tools/bin/bats tests/bats/bootstrap.bats`. Expected: FAIL.
- [ ] **Step 3:** Implement the files. The shared-home test hook `DEVENV_FAKE_FSTYPE` is read only when `.ci` is true.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit `feat: bootstrap and linux server tool layer`.

### Task 5: SSH: authorized_keys merge and GitHub key

**Files:**
- Create:
  - `lib/merge_authorized_keys.py`
  - `home/private_dot_ssh/modify_authorized_keys.tmpl`: `exec uv run --script {{ .chezmoi.workingTree }}/lib/merge_authorized_keys.py {{ .chezmoi.workingTree }}/ssh/authorized_keys.pub-list`.
  - `ssh/authorized_keys.pub-list`: the current single key.
  - `home/.chezmoiscripts/run_once_after_40-ssh-key.sh.tmpl`
  - `doctor.d/40-ssh.sh`
  - `tests/py/test_merge_authorized_keys.py`

**Interfaces:**
- Produces: `merge(existing: str, wanted: list[str]) -> str`.
  - Keeps every existing line in order and appends the wanted keys not already present, comparing the key type and key body only and ignoring the comment.
  - The output ends with exactly one newline.
- The key script does the following:
  - If `~/.ssh/id_ed25519` is missing: `ssh-keygen -t ed25519 -C "$USER@$(hostname)" -N "" -f ~/.ssh/id_ed25519`.
  - It prints the public key and `https://github.com/settings/ssh/new`, waits for Enter (skipped in CI), and then runs `ssh -T git@github.com`. It reports success when the output contains `successfully authenticated`; any other result is reported as a warning, not as a failure.

- [ ] **Step 1:** Write the tests:
  - `test_existing_lines_preserved_in_order`
  - `test_missing_key_appended`
  - `test_same_key_different_comment_not_duplicated`
  - `test_idempotent`: `merge(merge(x, w), w) == merge(x, w)`
  - `test_input_without_trailing_newline`: the current file has none.
  - `test_empty_existing`
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement. Doctor checks:
  - `~/.ssh/id_ed25519.pub` exists: FAIL if missing.
  - GitHub auth: SKIP in `--ci`.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then add an `@test "ssh key created once"` case to `bootstrap.bats` and run it.
- [ ] **Step 5:** Commit `feat: authorized_keys merge and github ssh key step`.

### Task 6: Secrets via Bitwarden with locked-vault skip

**Files:**
- Create:
  - `home/.chezmoitemplates/bw-field`: takes a dict `{item, field}`.
    - Returns the field value when `lookPath "bw"` succeeds and `bw status` reports `unlocked`.
    - Otherwise it calls `warnf "Bitwarden locked or missing: skipping %s" .target` and returns an empty string.
  - `home/dot_config/paper-search-mcp/private_dot_env.tmpl`: emits nothing if either field is empty, so chezmoi does not create the file.
  - `home/.chezmoiscripts/run_onchange_before_05-bw.sh.tmpl`: installs `bw` (npm `@bitwarden/cli` through fnm's Node, or a GitHub release binary on Windows).
  - `doctor.d/50-secrets.sh`
  - `tests/bats/secrets.bats`
- Modify: `docs/spec.md` Secrets section. Add the item names `paper-search` (fields `ieee_api_key`, `unpaywall_email`) and `ssh-hosts` (a JSON note, a list of `{alias, hostname, user, port}`).

**Interfaces:**
- Produces: the `bw-field` template, used by Tasks 10 and 11, for example `{{ template "bw-field" dict "item" "ssh-hosts" "field" "notes" "target" "~/.ssh/config" }}`.

- [ ] **Step 1:** Write `secrets.bats` with a stub `bw` on PATH. The stub prints a configurable status and item JSON.
  - `@test "unlocked vault renders paper-search env with both keys"`
  - `@test "locked vault: file absent and one warning"`
  - `@test "bw missing: file absent and one warning"`
  - `@test "apply exits 0 when locked"`
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit `feat: bitwarden-backed secrets with locked-vault skip`.

### Task 7: Claude Code

**Files:**
- Create:
  - `home/dot_claude/CLAUDE.md`: today's sections (Timezone, graphify, Semble Code Search, Advisor) plus a new **Agent orchestration** section. It is the project's "Model orchestration" section rewritten without project nouns:
    - No placer, DREAMPlace, hMETIS, evaluator, `env.sh` or pytest command.
    - Keep the role table, the dispatch rules, the Codex peer rules, and the end-of-run report.
    - Add one line saying that a project's own `.claude/agents/<role>.md` overrides the generic role.
  - `home/dot_claude/agents/{deep-reasoner,worker,fast-worker}.md`: generic versions of the project files, keeping their model and effort frontmatter.
  - `home/dot_claude/agents/{semble-search,researcher}.md`: copied from `~/.claude/agents`.
  - `home/dot_claude/settings.json.tmpl`: today's file. `enabledPlugins` and `extraKnownMarketplaces` are generated from the manifest; hooks and statusLine use `$HOME`.
  - `home/dot_claude/skills/<own skill>/`: only skills with no upstream installer. Decide per skill by checking how `paper-search`, `graphify`, `find-skills` and `codebase-memory` were installed:
    - The graphify and codebase-memory installers write their own skills.
    - find-skills comes from its upstream repo.
    - Record the upstream for the rest in the manifest.
  - `home/.chezmoiscripts/run_onchange_after_50-claude.sh.tmpl`, which:
    - Installs the native Claude Code if it is missing.
    - Runs `claude plugin marketplace add`, then `claude plugin install <name>@<marketplace>`, for each manifest entry not already installed.
    - Runs `claude mcp add -s user <name> -- <command> <args>` with locked versions, after `claude mcp remove -s user <name>` when the registered command differs.
    - Runs the codebase-memory-mcp upstream installer, which regenerates its hooks and agents.
  - `doctor.d/60-claude.sh`
  - `tests/bats/claude.bats`

**Interfaces:**
- Consumes: the manifest `mcp`, `claude.*` and `installers` entries (Task 3), and the PATH order (Task 2).
- Produces: `.claude/settings.json` keys `enabledPlugins` and `extraKnownMarketplaces`, built the same way as `bin/capture` reads them back (Task 11).

- [ ] **Step 1:** Write `claude.bats`:
  - `@test "settings.json renders valid JSON with every manifest plugin enabled"`
  - `@test "generic CLAUDE.md and agents mention no project nouns"`: grep for `DREAMPlace|placer|hMETIS|evaluator_gpu|env.sh|IO-Aware` finds nothing.
  - `@test "mcp add commands use locked versions and bare commands"`: render the script and assert it contains `semble[mcp]==<lock value>` and no `/` before `uvx` or `npx`.
  - `@test "claude install in container: doctor claude checks PASS or SKIP(login)"`: in Docker.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement. Doctor checks: `claude --version`; every manifest plugin appears in `claude plugin list`; every MCP appears in `claude mcp list`; login is SKIP in `--ci`.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit `feat: claude code instructions, agents, settings, plugins and mcp`.

### Task 8: Codex

**Files:**
- Create:
  - `lib/merge_codex_config.py`
  - `home/dot_codex/modify_config.toml.tmpl`: pipes the current file and a rendered managed fragment, `codex-managed.toml`, into the helper. The fragment holds `model`, `model_context_window`, `model_reasoning_effort`, `approvals_reviewer`, `[mcp_servers.*]` from the manifest with locked versions and bare commands, the hooks that call `codebase-memory-mcp hook-augment`, `tui.status_line`, and `tool_timeout_sec` on every MCP server.
  - `home/dot_codex/AGENTS.md`: copy of today's file with absolute paths removed.
  - `home/dot_codex/agents/{deep-reasoner,fast-worker}.toml`: generic versions of the project's `.codex/agents` files, keeping `gpt-6-astra` high and `gpt-5.6-terra` low.
  - `home/dot_codex/skills/codex-queue-workflow/`
  - `home/.chezmoiscripts/run_onchange_after_55-codex.sh.tmpl`: installs the Codex standalone build and the skill bundles at their locked versions, following `~/.codex/skill-bundles/installation-2026-09-14.md` with relative symlinks.
  - `doctor.d/65-codex.sh`
  - `tests/py/test_merge_codex_config.py`

**Interfaces:**
- Produces: `merge(existing_toml: str, managed_toml: str) -> str`.
  - Managed keys replace existing ones, and any `mcp_servers.*` table absent from the managed fragment is removed.
  - The `[projects.*]` tables, `hooks.state`, and every key not mentioned in the managed fragment are preserved.
  - Uses tomlkit and preserves comments.

- [ ] **Step 1:** Write the tests:
  - `test_project_trust_preserved`
  - `test_hooks_state_preserved`
  - `test_mcp_servers_replaced_wholesale`
  - `test_unknown_top_level_key_preserved`
  - `test_every_mcp_server_has_tool_timeout_sec`
  - `test_idempotent`
  - `test_empty_existing`
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement. Doctor checks: `codex --version`; every manifest MCP present; skills linked; login is SKIP in `--ci`.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then add `@test "codex install in container"` to `bootstrap.bats`.
- [ ] **Step 5:** Commit `feat: codex instructions, agents, managed config merge and skills`.

### Task 9: Status line releases

**Files:**
- Create:
  - `statusline/{main.go,go.mod}`: moved from `~/.claude/statusline`. Do not keep `build.sh`.
  - `statusline/main_test.go`
  - `.github/workflows/statusline-release.yml`: on tag `statusline-v*`, builds `statusline-linux-amd64`, `statusline-darwin-arm64` and `statusline-windows-amd64.exe` with `CGO_ENABLED=0`, and attaches them to the release.
  - `home/.chezmoiscripts/run_onchange_after_60-statusline.sh.tmpl` and its `.ps1` twin.
    - Download the asset for the locked `statusline` version (manifest source `github:yyds-tsai-dev/develop-env-settings`, tag prefix `statusline-v`) to `~/.claude/statusline-bin`.
    - If no release exists and `go` is on PATH, build locally.
    - Otherwise warn.

- [ ] **Step 1:** Write `TestRendersOneLineFromSampleInput`: feed a sample Claude Code status JSON (taken from the program's own input struct) on stdin and assert the program exits 0 and prints a non-empty line without a trailing blank line.
- [ ] **Step 2:** Run `cd statusline && go test ./...`. Expected: FAIL only if the test needs a seam; add the smallest seam needed.
- [ ] **Step 3:** Implement the workflow and the install scripts.
- [ ] **Step 4:** Run `go test ./...` and `GOOS=windows GOARCH=amd64 go build ./...`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: status line source, release workflow and installer`.

### Task 10: Desktop: WezTerm, font, VS Code, SSH config

**Files:**
- Create:
  - `bootstrap.ps1`: same flags and steps as `bootstrap.sh`; README one-liner `irm https://raw.githubusercontent.com/yyds-tsai-dev/develop-env-settings/main/bootstrap.ps1 | iex`.
  - `home/dot_wezterm.lua.tmpl`:
    - Font `JetBrainsMono Nerd Font`.
    - One colour scheme, chosen by the implementer and named in a comment.
    - `ssh_domains` generated from the Bitwarden `ssh-hosts` note, each with `multiplexing = "None"` and a `default_prog` of `{ "bash", "-lc", "tmux new -As wez" }`.
    - An empty `ssh_domains` list when the vault is locked.
  - `home/private_dot_ssh/config.tmpl`: Desktop only, from the same note. It renders empty, so the file is not created, when the vault is locked.
  - `home/.chezmoiscripts/run_onchange_after_70-desktop.ps1.tmpl` (Windows) and `run_onchange_after_70-desktop.sh.tmpl` (macOS):
    - Install WezTerm, git, gh and VS Code (winget user scope, or brew cask).
    - Install JetBrainsMono Nerd Font into the user font directory.
    - Print the commands that need admin rights.
  - `run_onchange_after_75-mac-server.sh.tmpl`: when role is `desktop+server`, brew installs the `cli_tools` list, then runs the same Node, uv, Claude and Codex scripts.
  - `desktop/vscode/settings-sync.jsonc`:
    - `remote.SSH.defaultExtensions`: the 15 current server extensions.
    - `terminal.integrated.fontFamily`: `"JetBrainsMono Nerd Font"`.
  - `desktop/vscode/server-extensions.txt`
  - `bin/vscode-server-extensions`: fallback using `code --install-extension` from a VS Code-connected terminal.
  - `doctor.d/70-desktop.ps1` and `doctor.d/70-desktop.sh`
  - `tests/bats/desktop.bats`

- [ ] **Step 1:** Write `desktop.bats` with the `bw` stub from Task 6.
  - `@test "wezterm config has one ssh domain per host with tmux new -As wez"`
  - `@test "locked vault: wezterm config renders with empty ssh_domains and no ~/.ssh/config"`
  - `@test "settings-sync.jsonc lists every server extension"`: compares against `server-extensions.txt`.
  - `@test "desktop role on darwin ignores server-only files"`
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it. Expected: PASS. CI's macOS and Windows jobs run `bootstrap --role desktop --ci` and then doctor.
- [ ] **Step 5:** Commit `feat: desktop wezterm, nerd font, vscode settings sync and ssh config`.

### Task 11: Capture, agent instructions, README, CI matrix

**Files:**
- Create:
  - `bin/capture`, which:
    - Runs `chezmoi re-add`.
    - Rewrites `desktop/vscode/server-extensions.txt` from `~/.vscode-server/extensions`.
    - Rewrites the manifest `claude.plugins` and `claude.marketplaces` from `claude plugin list` and `marketplace list`.
    - Rewrites the manifest `uv_tools` from `uv tool list`.
    - Rewrites the manifest `cli_tools` and `pdftools` from `micromamba env export --from-history`.
    - Prints `git -C <repo> diff --stat` and does not commit.
  - `tests/bats/capture.bats`: fixtures under a fake HOME.
  - `AGENTS.md` and the symlink `CLAUDE.md -> AGENTS.md`. Contents:
    - Bootstrap order.
    - The person-only steps: Bitwarden login and unlock, GitHub key upload, `claude` login, `codex login`, and any printed admin-rights commands.
    - The rule never to run on a Server whose home is shared and in use without the person's go-ahead.
    - Done when `bin/doctor` reports no FAIL.
  - `README.md`: the one-liners for Linux, macOS and Windows; roles; update; capture; rollback by `git checkout <rev> -- home/.chezmoidata/versions.yaml && chezmoi apply`.
- Modify: `.github/workflows/ci.yml`:
  - Ubuntu job runs the Docker Server test.
  - macOS job runs desktop and desktop+server.
  - Windows job runs desktop.
  - All jobs run `bin/doctor --ci` (or `bin/doctor.ps1 --ci`).

- [ ] **Step 1:** Write `capture.bats`:
  - `@test "capture rewrites extension list from fake vscode-server dir"`
  - `@test "capture leaves the repo uncommitted"`
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the full local suite:
  - `.tools/bin/bats tests/bats`
  - `uv run --with pytest --with pyyaml --with tomlkit pytest tests/py`
  - `cd statusline && go test ./...`

  Expected: all PASS.
- [ ] **Step 5:** Commit `feat: capture, agent instructions, readme, full ci matrix`.
