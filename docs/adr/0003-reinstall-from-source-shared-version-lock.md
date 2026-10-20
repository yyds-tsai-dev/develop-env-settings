# Reinstall third-party agent tooling from source, one shared Version lock

Third-party Claude Code plugins, Codex skill bundles and MCP servers are not vendored; the Manifest names them and each install or update resolves their latest release, writes that exact version into both the Claude Code and Codex configuration, and records it in the Version lock. Only the person's own work (instructions, generic agents, the status line, small shell hooks) is vendored. This was chosen after the two tools had silently drifted apart (drawio MCP `@latest` vs `0.2.3`, superpowers 7.0.0 vs a 6.3.0 bundle).
