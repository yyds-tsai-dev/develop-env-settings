# Installation and verification, 2026-09-23

## Scope

The user requested improvements to the current Codex agent/harness based on the supplied Reddit queue workflow and Concrete333/Codex-Delegation-Deployment. Installed a global skill at `~/.codex/skills/codex-queue-workflow` and replaced only the managed `codex-efficient-waiting` block in `~/.codex/AGENTS.md` with a compact routing entry.

The coordinator model, `config.toml`, MCP configuration and unrelated global instructions are unchanged. No placement-project files were edited. The indexed placement-project graph does not cover this global skill; global file inspection and the pinned external source were the evidence used here.

Backup: `~/.codex/backups/queue-workflow-20260923T075242Z/` contains the original `AGENTS.md` and `config.toml`. For rollback, restore only the old managed waiting block if later edits have occurred; remove this skill only after no active job depends on its helper. Do not restore a whole stale config over newer changes.

## Evidence

- Local CLI: `codex-cli 0.156.1`; `codex queue --help` confirms `--thread` and `--message`.
- Upstream source revision: `edff78658635eef7a1a0f81937fabe5a9107ec41`.
- Baseline: all 16 upstream tests passed. Six local contract tests failed before fixes; duplicate-start protection already passed.
- Final suite: 25 tests passed, including the upstream suite, restrictive POSIX permissions, supervisor replay prevention, durable PID/UUID/cwd, premature callback rejection, mismatched thread rejection and supervisor spawn failure evidence.
- Skill frontmatter validator: passed.
- Exact comparisons: `config.toml` is unchanged; global instructions outside the managed waiting block are unchanged.
- No subscription-cost reduction was measured. No cross-platform or host-reboot reliability claim is made. Mocked tests do not establish host delivery.

## Live smoke test and completed acceptance gate

- Parent UUID: `01a0cd3a-d21d-7ca2-ad8e-34884d397ea8` from the current `CODEX_THREAD_ID`.
- Job ID: `smoke-20260923`.
- Supervisor PID: `3387580`.
- Working directory: `~/.codex/skills/codex-queue-workflow`.
- Result: `~/.codex/queue-jobs/smoke-20260923/process.json`.
- Command completed with exit code 0 and expected stdout `queue-workflow smoke: command completed`.
- Delivery file: `~/.codex/queue-jobs/smoke-20260923/process.notification.json`.
- Queue submission succeeded, message ID `01a0cd43-40ad-7402-b6ef-0a67c7184bd1`. The CLI also emitted a stale temporary-directory cleanup warning; it did not prevent accepted submission and does not justify a resend.
- Parent consumption/wake-up: **verified**. After the original turn ended, the queued completion message resumed the same parent UUID. The callback turn checked the terminal result, expected output and queue receipt. Durable acceptance: `~/.codex/queue-jobs/smoke-20260923/acceptance.json`. This demonstrates delivery in the tested local session, not guaranteed delivery after host loss or in every environment.

The smoke result has been accepted and handled. No repeated job, notification resend or polling loop was used. All installation acceptance gates are complete; no background work remains for this task.
