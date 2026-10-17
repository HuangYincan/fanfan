#!/bin/bash
set -euo pipefail
SUPPORT_SOURCE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/fanfan-launchd-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
TARGET=system/com.huangyincan.fanfan.local.helper
reset_fixture() {
    FANFAN_STOP_TARGET=''
    FANFAN_STOP_PID=''
    printf '0\n' > "$FIXTURE/tick"
    printf '0\n' > "$FIXTURE/stop"
    printf '1\n' > "$FIXTURE/old-job"
    printf '1\n' > "$FIXTURE/old-pid"
    printf '0\n' > "$FIXTURE/new-job"
    printf '0\n' > "$FIXTURE/fail-bootstrap"
    printf '0\n' > "$FIXTURE/fail-start"
    : > "$FIXTURE/calls"
}
fanfan_launchctl() {
    printf '%s\n' "$*" >> "$FIXTURE/calls"
    case "$1" in
        print)
            if [ "$(cat "$FIXTURE/old-job")" -eq 1 ]; then
                printf 'state = running\npid = 123\n'; return 0
            fi
            if [ "$(cat "$FIXTURE/new-job")" -eq 1 ]; then
                if [ "$(cat "$FIXTURE/fail-start")" -eq 1 ]; then
                    printf 'state = spawn scheduled\n'; return 0
                fi
                printf 'state = running\npid = 456\n'; return 0
            fi
            return 113 ;;
        bootout)
            if [ "$(cat "$FIXTURE/old-job")" -eq 1 ] || [ "$(cat "$FIXTURE/new-job")" -eq 1 ]; then
                printf '1\n' > "$FIXTURE/stop"; return 0
            fi
            return 113 ;;
        bootstrap)
            if [ "$(cat "$FIXTURE/old-job")" -eq 1 ] || [ "$(cat "$FIXTURE/old-pid")" -eq 1 ]; then
                echo 'Bootstrap failed: 5: Input/output error (old service still exiting)' >&2; return 5
            fi
            if [ "$(cat "$FIXTURE/fail-bootstrap")" -eq 1 ]; then return 5; fi
            printf '1\n' > "$FIXTURE/new-job"; return 0 ;;
        enable|kickstart) return 0 ;;
        *) echo "Unexpected launchctl call: $*" >&2; return 2 ;;
    esac
}
fanfan_pid_alive() {
    case "$1" in
        123) test "$(cat "$FIXTURE/old-pid")" -eq 1 ;;
        456) test "$(cat "$FIXTURE/new-job")" -eq 1 ;;
        *) return 1 ;;
    esac
}
fanfan_wait_tick() {
    tick="$(cat "$FIXTURE/tick")"; tick=$((tick + 1))
    printf '%s\n' "$tick" > "$FIXTURE/tick"
    if [ "$(cat "$FIXTURE/stop")" -eq 1 ]; then
        if [ "$tick" -ge 3 ]; then printf '0\n' > "$FIXTURE/old-job"; fi
        if [ "$tick" -ge 5 ]; then
            printf '0\n' > "$FIXTURE/old-pid"
            printf '0\n' > "$FIXTURE/new-job"
        fi
    fi
}

reset_fixture
if [ "${1:-}" = --old-order ]; then
    fanfan_launchctl bootout "$TARGET"
    fanfan_launchctl bootstrap system /fixture/helper.plist
    exit 0
fi

# Load production lifecycle functions, then replace only operating-system calls.
declare -f fanfan_launchctl fanfan_pid_alive fanfan_wait_tick > "$FIXTURE/mock.sh"
source "$SUPPORT_SOURCE/launchd-service.sh"
source "$FIXTURE/mock.sh"

reset_fixture
fanfan_stop_service "$TARGET" 8
test "$(cat "$FIXTURE/tick")" -eq 5
fanfan_start_service "$TARGET" /fixture/helper.plist 3
echo 'PASS: upgrade waits for both service removal and old process exit'

# Rollback uses the same stop/start path after a partially started new job.
printf '0\n' > "$FIXTURE/tick"
printf '0\n' > "$FIXTURE/stop"
fanfan_stop_service "$TARGET" 8
fanfan_start_service "$TARGET" /fixture/previous.plist 3
echo 'PASS: rollback waits before re-registering the previous service'

reset_fixture
printf '0\n' > "$FIXTURE/old-job"
printf '0\n' > "$FIXTURE/old-pid"
fanfan_stop_service "$TARGET" 3
test "$(cat "$FIXTURE/tick")" -eq 0
fanfan_start_service "$TARGET" /fixture/helper.plist 3
echo 'PASS: an already-unloaded service can be installed immediately'

reset_fixture
if fanfan_stop_service "$TARGET" 2; then echo 'FAIL: premature stop success' >&2; exit 1; fi
case "$(cat "$FIXTURE/calls")" in *bootstrap*) echo 'FAIL: bootstrapped before stop' >&2; exit 1;; esac
echo 'PASS: stop timeout is a failure and cannot proceed to bootstrap'

reset_fixture
if fanfan_stop_service "$TARGET" 4; then echo 'FAIL: lost the still-exiting PID' >&2; exit 1; fi
test "$(cat "$FIXTURE/old-job")" -eq 0
test "$(cat "$FIXTURE/old-pid")" -eq 1
fanfan_stop_service "$TARGET" 3
test "$(cat "$FIXTURE/tick")" -eq 5
fanfan_start_service "$TARGET" /fixture/previous.plist 3
echo 'PASS: recovery remembers the old PID after its job definition disappears'

reset_fixture
printf '0\n' > "$FIXTURE/old-job"
printf '0\n' > "$FIXTURE/old-pid"
printf '1\n' > "$FIXTURE/fail-bootstrap"
if fanfan_start_service "$TARGET" /fixture/helper.plist 3; then echo 'FAIL: ignored bootstrap failure' >&2; exit 1; fi
echo 'PASS: a genuine bootstrap failure is preserved'

reset_fixture
printf '0\n' > "$FIXTURE/old-job"
printf '0\n' > "$FIXTURE/old-pid"
printf '1\n' > "$FIXTURE/fail-start"
if fanfan_start_service "$TARGET" /fixture/helper.plist 3; then echo 'FAIL: reported stopped helper as running' >&2; exit 1; fi
echo 'PASS: service registration alone cannot report a successful startup'
