# Develop Env Settings

One person's portable development environment: the shell, terminal, editor-remote, language-toolchain and agentic-tool setup that a fresh machine should end up with after one bootstrap.

## Machines

**Server**:
A Linux machine where development actually happens (code, builds, agents), reached remotely; it receives the full environment without needing admin rights.
_Avoid_: host, box, remote, dev machine

**Desktop**:
A Windows or macOS machine the person sits at; it carries the client side (editor, terminal emulator, SSH identity, fonts) plus Claude Code, and gets Codex and the Server tools only when it also opts into the Server role.
_Avoid_: client, local machine, laptop

**Shared home**:
A home directory mounted from network storage, so every Server that mounts it already sees the same files; only machine-local pieces need to be set up there.
_Avoid_: NAS home, LDAP home, NFS home

## Contents

**Personal environment**:
Everything that follows the person across all projects; project-specific toolchains and secrets belong to each project, not here.
_Avoid_: dotfiles (too narrow), global config

**Manifest**:
The declared list of tools, plugins, skills and MCP servers the environment should contain, each tracking its latest release.
_Avoid_: package list, requirements

**Version lock**:
The record of the exact versions the Manifest resolved to at the last install or update, shared by every agent tool so they never drift apart.
_Avoid_: pin file, versions file

**Secret**:
A value that must never enter the repository (API keys, logins, host addresses); it lives in the person's password vault and is filled in on each machine.
_Avoid_: credential, token (as general terms)

**Agent orchestration**:
The person's standing arrangement of which AI model plays scheduler and which plays each specialist role; the generic form lives here, and a project may override a role with a domain-specific version.
_Avoid_: model routing, agent team

## Lifecycle

**Bootstrap**:
The single first step on a new machine that fetches this repository and brings the machine to the declared environment.
_Avoid_: setup, provisioning

**Capture**:
Pulling state that changed on a live machine back into the repository so the next Bootstrap reproduces it.
_Avoid_: sync, export, backup

**Doctor**:
The check that a machine matches the declared environment, reporting each item as pass or fail; a Bootstrap counts as done only when Doctor passes.
_Avoid_: verify, health check
