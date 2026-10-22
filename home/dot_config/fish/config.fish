# Machine-specific overrides live in config.local.fish (untracked). It is
# sourced outside any `status is-interactive` guard, so every fish (interactive
# or not: scripts, `fish -c`) gets the environment it sets.
if test -f $HOME/.config/fish/config.local.fish
    source $HOME/.config/fish/config.local.fish
end
