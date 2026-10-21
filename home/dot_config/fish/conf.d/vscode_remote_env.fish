# Keep VS Code Remote env fresh in long-lived tmux panes.
# A tmux pane keeps the env it (or the tmux server) started with. After the
# VS Code server updates or the client reconnects, VSCODE_IPC_HOOK_CLI and the
# remote-cli PATH entry go stale, so `code` fails. Before each command, re-point
# them at the running server and its live socket.
status is-interactive; or exit
set -q TMUX; or exit

# Newest socket matching a prefix that some process is still listening on.
function __vscode_live_sock -a prefix
    set -l socks /run/user/(id -u)/$prefix-*.sock /tmp/$prefix-*.sock
    test (count $socks) -gt 0; or return 1
    set -l listening (ss -xlH 2>/dev/null | string match -r '\S+\.sock')
    for s in (ls -t $socks 2>/dev/null)
        if test -O $s; and contains -- $s $listening
            echo $s
            return 0
        end
    end
    return 1
end

function __vscode_refresh_env --on-event fish_preexec
    set -l listening (ss -xlH 2>/dev/null | string match -r '\S+\.sock')
    # Fast path: current value still valid.
    if contains -- "$VSCODE_IPC_HOOK_CLI" $listening
        return
    end

    # Server root of the running VS Code server (dir holding node + out/server-main.js).
    set -l main (pgrep -u (id -u) -af 'vscode-server/.*/out/server-main\.js' | string match -r '\S+/out/server-main\.js' | tail -1)
    set -l srv (string replace -r '/out/server-main\.js$' '' -- $main)

    # `code`: remote-cli on PATH + live CLI socket.
    set -l ipc (__vscode_live_sock vscode-ipc)
    if test -n "$srv" -a -n "$ipc"
        set -l cli $srv/bin/remote-cli
        set -gx PATH $cli (string match -v -r 'vscode-server/.*/remote-cli$' -- $PATH)
        set -gx VSCODE_IPC_HOOK_CLI $ipc
    end
end
