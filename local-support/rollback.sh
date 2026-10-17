#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
    exec sudo /bin/bash "$0"
fi
SUPPORT_DIR="/Library/Application Support/FanFanLocal"
BACKUP="$(cat "$SUPPORT_DIR/last-backup")"
case "$BACKUP" in "$SUPPORT_DIR"/backups/official-*.zip) ;; *) echo 'Invalid backup path' >&2; exit 1;; esac
test -f "$BACKUP"
umask 077
RESTORE_STAGE="$(mktemp -d /private/tmp/fanfan-rollback.XXXXXX)"
trap 'rm -rf "$RESTORE_STAGE"' EXIT
/usr/bin/ditto -x -k "$BACKUP" "$RESTORE_STAGE"
/usr/bin/codesign --verify --deep --strict "$RESTORE_STAGE/fanfan.app"
/usr/bin/pkill -TERM -x fanfan 2>/dev/null || true
for attempt in {1..30}; do
    if ! /usr/bin/pgrep -x fanfan >/dev/null; then break; fi
    /bin/sleep 0.2
done
if /usr/bin/pgrep -x fanfan >/dev/null; then
    echo 'App did not exit; rollback stopped before replacement' >&2; exit 1
fi
/Library/PrivilegedHelperTools/fanfan-local-smcd --restore-system
/bin/launchctl bootout system/com.huangyincan.fanfan.local.helper 2>/dev/null || true
/bin/launchctl disable system/com.huangyincan.fanfan.local.helper
/bin/rm -rf /Applications/fanfan.app
/usr/bin/ditto "$RESTORE_STAGE/fanfan.app" /Applications/fanfan.app
/usr/sbin/chown -R root:wheel /Applications/fanfan.app
/bin/launchctl enable system/com.hoobnn.fanfan.helper 2>/dev/null || true
/bin/launchctl bootstrap system /Applications/fanfan.app/Contents/Library/LaunchDaemons/com.hoobnn.fanfan.helper.plist 2>/dev/null || true
/bin/launchctl kickstart system/com.hoobnn.fanfan.helper 2>/dev/null || true
echo 'Original signed app restored. Open /Applications/fanfan.app; it can re-register its official helper if needed.'
