# Provenance and local changes

Installed 2026-09-23 from the user-provided workflow and [Concrete333/Codex-Delegation-Deployment](https://github.com/Concrete333/Codex-Delegation-Deployment), revision `edff78658635eef7a1a0f81937fabe5a9107ec41`.

`scripts/completion_notify.py` and `tests/test_completion_notify.py` originate from that revision. The local helper adds private POSIX files, durable job identity/PID/timestamps, an exclusive supervisor execution claim, rejection of premature or mismatched receipt notification, and an explicit newer-stop/pause reminder. `tests/test_local_contract.py` covers these additions. Do not overwrite local changes with an unreviewed pull.

The skill and references adapt the upstream waiting/delegation approach and the Reddit text supplied in the conversation. Upstream source links:

- [Scripts and test suites](https://github.com/Concrete333/Codex-Delegation-Deployment#scripts-and-test-suites)
- [Waiting workflow](https://github.com/Concrete333/Codex-Delegation-Deployment/blob/edff78658635eef7a1a0f81937fabe5a9107ec41/references/waiting.md)
- [Supervisor source](https://github.com/Concrete333/Codex-Delegation-Deployment/blob/edff78658635eef7a1a0f81937fabe5a9107ec41/scripts/completion_notify.py)

Compatibility was checked against local `codex-cli 0.156.1`, including actual `codex queue --help`. CLI acceptance does not establish consumption by the host. See the installation report for live delivery results.

The upstream optional 25-minute native-agent wait configuration was not applied: this session's higher-priority tools limit blocking waits, and a long wait setting does not establish completion delivery. The coordinator model, MCP hooks and permission settings were preserved. External providers and recurring automation were not needed.
