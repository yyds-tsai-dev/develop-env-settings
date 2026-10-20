# Command supervisor

Requires Python 3.10+ and a Codex executable with `queue --thread --message`. Local entry point:

```bash
python3 ~/.codex/skills/codex-queue-workflow/scripts/completion_notify.py --help
```

Use the absolute Python/helper/Codex paths actually installed on the host. This setup installs it as `~/.local/bin/codex`. Do not copy the Reddit author's macOS paths.

## Launch

Create a private request using an argument array, not shell interpolation. This example runs one harmless command. Replace the command with the authorized foreground job and choose a unique job ID for every legitimate attempt:

```bash
python3 - <<'PY'
import json, os, shutil, sys, uuid
from pathlib import Path

root = Path.home() / '.codex' / 'queue-jobs'
root.mkdir(mode=0o700, exist_ok=True)
job_id = 'check-' + uuid.uuid4().hex
request_path = root / (job_id + '.request.json')
request = {
    'codex': shutil.which('codex'),
    'thread': os.environ['CODEX_THREAD_ID'],
    'cwd': str(Path.cwd()),
    'argv': [sys.executable, '-c', "print('finished')"],
}
with os.fdopen(os.open(request_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f:
    json.dump(request, f)
print('Request:', request_path)
print('Run directory:', root / job_id)
PY
```

Then use the exact paths returned:

```text
python3 ~/.codex/skills/codex-queue-workflow/scripts/completion_notify.py start --request ABSOLUTE_REQUEST_JSON --run-dir ABSOLUTE_NEW_JOB_DIRECTORY
```

`start` validates UUID, CLI capability, executable and working directory; atomically reserves the job directory; saves the request; detaches a supervisor; persists its PID; and returns the result path. An existing job directory fails instead of launching twice. The `_run` execution claim also prevents supervisor replay. Never manually delete claims to retry work.

The helper adds no execution timeout or process-tree cancellation. For finite suites that need a hard limit on Linux, use a suitable `timeout --kill-after=... ...` command in `argv`, after checking that command's cleanup semantics fit the job. Keep the foreground command responsible for its children. Do not use this helper for interactive services or daemon launchers.

## Saved evidence

| File | Meaning |
| --- | --- |
| `request.json` | Parent UUID, absolute cwd, argv and optional worker receipt path |
| `supervisor.json` | Detached supervisor PID and job identity |
| `execution.claim` | Exclusive execution claim; existence blocks replay |
| `execution.json` | Start metadata; `running` is a historical observation, not a liveness guarantee |
| `stdout.log`, `stderr.log` | Command output |
| `supervisor.log` | Supervisor diagnostics |
| `process.json` | Terminal exit/launch failure, UUID, cwd, supervisor PID and timestamps |
| `process.notification.json` | Queue attempt and its outcome, independent of job success |

On POSIX, job directories use mode 0700 and state/log files use 0600 even under a permissive umask. These protect against other users, not an executor running as the same user. No sandbox or additional permissions are supplied by this helper. A killed supervisor or lost host can leave only a claim/start record; that is unresolved execution, not proof of termination.

## Notification recovery

Only after a completion event, an explicit status request or a concrete notification failure, inspect these records once. If a terminal result exists **and no notification attempt exists**, submit it with the recorded UUID:

```text
python3 ~/.codex/skills/codex-queue-workflow/scripts/completion_notify.py notify --codex ABSOLUTE_CODEX --thread RECORDED_PARENT_UUID --receipt ABSOLUTE_JOB_DIRECTORY/process.json
```

The helper rejects a conflicting receipt UUID and a nonterminal receipt. An existing attempt is returned without a second submission. Failed/unknown/attempting delivery requires diagnosis; do not delete the record or automatically resend. Missing, malformed or incomplete state requires a handoff with the exact gap.

## Validation

```bash
python3 -m unittest discover -s ~/.codex/skills/codex-queue-workflow/tests -v
```

Tests use local fixtures/mocks for queue calls and never submit real callbacks. A live smoke test is a separate check against the actual current parent UUID. The CLI's successful submission and an observed parent wake-up are different validation gates.
