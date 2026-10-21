---
name: codex-queue-workflow
description: Use when launching asynchronous commands, long tests, builds or CI watchers, or arranging completion for authorized executors. Provides durable results and one-shot Codex queue callbacks without model-driven polling.
---

# Queue completion, then yield

Let a process wait; resume the parent on completion. Keep known-short commands direct. For native agents, prefer a completion event that already wakes the parent. This skill does not authorize delegation or expand execution permissions.

## Before launch

1. Record the exact parent task UUID from the current runtime, such as `CODEX_THREAD_ID`, the unique job ID, absolute working directory, command, result location, and acceptance checks. Never infer a UUID from an agent path or select the most recent session.
2. Establish the completion route before starting work. Check `codex queue --help` once per environment; the bundled helper also validates `--thread` and `--message` before each launch. CLI support proves syntax, not delivery or automatic wake-up. Retain a successful receipt and an observed callback as separate evidence.
3. Detach only an authorized, noninteractive foreground command that safely survives a turn ending. The command owns its work timeout and child cleanup. A shell launcher that exits before its work finishes is unsuitable. Keep supervisor code and state outside worker-owned paths. Keep credentials out of argv and callbacks.
4. For commands, use [the bundled helper](references/commands.md). Register the target and result path in the request before launch; the supervisor saves the terminal result, then submits one callback. For authorized agents, also read [the task contract](references/delegation.md).

## While work runs

Do useful independent work once, then yield the turn. State the job ID, result location and remaining validation. Say notification is armed until delivery is observed. Keep the host available.

Do not repeatedly invoke status/list/wait, reread unchanged logs or partial diffs, send check-in messages, or restart goal turns merely to observe an unfinished job. Do not use another model to wait. Do not manufacture review activity. A wait timeout is not a job failure and never justifies a replacement run.

Existing jobs keep their original process/session identifiers. Attach only through their supported completion/wait interface; never pass the original launcher to the helper again. For CI, a process may run `gh run watch RUN_ID --exit-status --interval 60`; its ordinary polling does not consume model turns. Keep meaningful work timeouts intact.

## Completion and recovery

First honor newer user stop, pause or scope changes. Correlate by job directory/ID; native and queued signals may describe the same job. Handle each completed checkpoint once.

Read `process.json`, delivery state and the relevant artifact/test evidence. Exit code zero, a queued message and worker claims are not acceptance. Review changed behavior and batch defects into one correction task. Reuse passing evidence for unchanged code. Interrupt early only for a concrete blocker, conflicting writes, an authorization problem or user steering.

`process.notification.json` records one attempted submission: `attempting`, `queued`, `failed` or `unknown`. An existing attempt suppresses retries, including after a crash or ambiguous timeout. `queued` means the CLI accepted submission; it does not prove the parent consumed it. If no attempt exists and a terminal receipt does, the documented `notify` command can submit it. Never rerun a job just to repair notification. Never write Codex's internal queue database.

Inspect failed work once, identify the cause and confirm termination/ownership before an authorized safe replay with a new job ID. Preserve the old evidence. A notification failure is separate from command failure. An explicit status request or known failed notification permits one targeted diagnostic.

## Unavailable completion route

If the UUID, CLI, host permissions or supported wake-up route is unavailable, name the specific limitation once. Preserve safely running work, identifiers, logs and remaining acceptance checks in a durable handoff. Tell the user that they must return to resume validation; do not claim automatic wake-up. Do not replace this with repeated model polling or create recurring automation/new tasks.

## Cost and scope

Queueing removes orchestration polling; it does not make workers free. Count preparation, execution, review and corrections when evaluating delegation. Raw token counts and API-equivalent estimates are not subscription allowance percentages. Preserve the active task; callbacks are completion signals, not new work authorization.
