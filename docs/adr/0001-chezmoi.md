# Use chezmoi to manage the environment

The environment must reach Linux Servers without admin rights plus Windows and macOS Desktops, with per-OS and per-machine differences and Secrets filled in at install time. We chose chezmoi over a hand-written symlink script or GNU stow because it handles all three operating systems, templating, run-once install scripts, secret lookups and reverse capture (`chezmoi re-add`, `chezmoi diff`) natively, at the cost of a single extra binary and its source-state naming rules.
