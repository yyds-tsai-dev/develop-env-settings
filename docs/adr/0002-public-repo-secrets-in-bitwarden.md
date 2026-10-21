# Public repository, Secrets in Bitwarden

The repository is public so a new machine can Bootstrap with one command before it has any GitHub credentials. In exchange nothing sensitive is ever committed: API keys, emails used as API identities, SSH host addresses and usernames all live in the person's Bitwarden vault and are read by chezmoi templates at apply time. If the vault is locked, files that need a Secret are skipped with a warning and everything else still installs.
