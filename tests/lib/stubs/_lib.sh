# shellcheck shell=bash
# Shared by the command stubs in this directory. Sourced, not run.
# The stubs stand in for remote/network commands so the workflows can run on
# this machine: "server:" paths become local paths, ssh runs its command here.
# Every call is appended to $STUB_LOG (one line, tab-separated) when set, so a
# test can see what ran and in what order.
STUB_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

stub_log() {
    if [ -n "${STUB_LOG:-}" ]; then
        local IFS=$'\t'
        printf '%s\n' "$*" >> "$STUB_LOG"
    fi
}

# The real binary for $1: the first one on PATH that isn't a stub.
real_bin() {
    local dir IFS=:
    for dir in $PATH; do
        [ "$(cd "$dir" 2>/dev/null && pwd)" = "$STUB_SELF_DIR" ] && continue
        if [ -x "$dir/$1" ] && [ ! -d "$dir/$1" ]; then
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done
    echo "stub: no real $1 on PATH" >&2
    return 127
}

# host:path or user@host:path -> local path. ~ and relative paths are taken
# from $STUB_REMOTE_HOME, as a login shell on the server would.
map_remote_path() {
    local p="$1"
    case "$p" in
        \~) p="${STUB_REMOTE_HOME:-$HOME}" ;;
        \~/*) p="${STUB_REMOTE_HOME:-$HOME}/${p#\~/}" ;;
        /*) ;;
        *) p="${STUB_REMOTE_HOME:-$HOME}/$p" ;;
    esac
    printf '%s\n' "$p"
}

is_remote_arg() {
    [[ "$1" != -* && "$1" != /* && "$1" =~ ^[A-Za-z0-9_.@-]+: ]]
}
