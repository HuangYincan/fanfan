#!/bin/bash
# launchctl bootout may return before the job and its process have disappeared.
# Keep the OS calls behind small functions so the real lifecycle sequence can
# be replayed without root privileges or changing the host's launchd domain.
FANFAN_STOP_TARGET=''
FANFAN_STOP_PID=''
fanfan_launchctl() { /bin/launchctl "$@"; }
fanfan_pid_alive() { /bin/kill -0 "$1" 2>/dev/null; }
fanfan_wait_tick() { /bin/sleep 0.1; }
fanfan_service_pid() {
    printf '%s\n' "$1" | /usr/bin/awk '$1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3 }'
}

fanfan_stop_service() {
    local target="$1" limit="${2:-200}" state old_pid attempt
    state="$(fanfan_launchctl print "$target" 2>/dev/null)" || state=''
    old_pid="$(fanfan_service_pid "$state")"
    if [ -n "$old_pid" ]; then
        FANFAN_STOP_TARGET="$target"
        FANFAN_STOP_PID="$old_pid"
    elif [ "$FANFAN_STOP_TARGET" = "$target" ]; then
        old_pid="$FANFAN_STOP_PID"
    fi
    fanfan_launchctl bootout "$target" 2>/dev/null || true
    for ((attempt=0; attempt<limit; attempt++)); do
        if ! fanfan_launchctl print "$target" >/dev/null 2>&1; then
            if [ -z "$old_pid" ] || ! fanfan_pid_alive "$old_pid"; then
                FANFAN_STOP_TARGET=''
                FANFAN_STOP_PID=''
                return 0
            fi
        fi
        fanfan_wait_tick
    done
    echo "Timed out waiting for $target to unload (previous PID: ${old_pid:-none})" >&2
    fanfan_launchctl print "$target" >&2 || true
    return 1
}

fanfan_start_service() {
    local target="$1" plist="$2" limit="${3:-100}" state pid attempt
    fanfan_launchctl enable "$target" || return $?
    fanfan_launchctl bootstrap system "$plist" || return $?
    fanfan_launchctl kickstart "$target" || return $?
    for ((attempt=0; attempt<limit; attempt++)); do
        state="$(fanfan_launchctl print "$target" 2>/dev/null)" || state=''
        pid="$(fanfan_service_pid "$state")"
        case "$state" in
            *'state = running'*)
                if [ -n "$pid" ] && fanfan_pid_alive "$pid"; then return 0; fi ;;
        esac
        fanfan_wait_tick
    done
    echo "Service registered but did not become a running process: $target" >&2
    fanfan_launchctl print "$target" >&2 || true
    return 1
}
