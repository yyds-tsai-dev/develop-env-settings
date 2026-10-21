# Bounded executor assignments

Delegate only when the user or applicable higher-level instructions authorize it, and when a concrete independent task removes work from the coordinator. Keep short deterministic work in commands. Keep tightly coupled edits with one owner. Preserve the coordinator model and existing model-selection policy.

The quoted Reddit author's `gpt-5.6-luna`/`xhigh` setting is an example, not a universal override. If the user explicitly selects it, set both controls and verify availability; otherwise use the authorized task-appropriate model. Never silently substitute. Full-history forks may inherit the parent model and prevent overrides; use a minimal explicit contract when supported.

## Initial task contract

```text
Job ID / exact parent UUID / working directory / result path:
Outcome and non-goals:
Owned files and shared-state owner:
Settled interfaces and decisions:
Relevant source paths and evidence:
Acceptance criteria and verification commands:
Allowed side effects, work timeout and failure checkpoint:
Completion route and verification owner:
Return: complete | partial | blocked; changed files, test results and remaining risks.
```

Tell an editing worker that others share the codebase: preserve their changes and stay within assigned ownership. Use separate worktrees when concurrent edits require isolation. Include the applicable project instructions. For indexed code, pass the graph project/generation, evidence tier, queries/pagination, qualified symbols, path coverage gaps and source fallbacks required by the global codebase-memory instructions. Global configuration outside an indexed project needs direct file evidence; do not pretend the project graph covers it.

Choose exactly one normal completion route. Native agents that already wake the parent need no second queue callback. For a detached CLI worker, supervise its foreground CLI process and have it finish verification and write its receipt before exit; the supervisor queues the process receipt. Do not also ask that worker to send a duplicate callback. If the worker itself owns the callback, supply the exact parent UUID and job/result path in its initial assignment, and queue only after writing the terminal receipt.

Workers receive the contract and relevant evidence, not benchmark collections or the entire conversation. The coordinator does independent necessary work while they run, then yields. Review their completed diff, substantive behavior and verification evidence once; batch findings into one correction assignment. Worker tests are evidence, not automatic acceptance. Reuse the same owner for bounded corrections; resolve ownership before transferring edits.
