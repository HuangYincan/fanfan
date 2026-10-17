#!/bin/bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$(id -u)" -ne 0 ]; then
    exec sudo /bin/bash "$PACKAGE_DIR/install.sh"
fi
umask 077
INSTALL_STAGE="$(mktemp -d /private/tmp/fanfan-install.XXXXXX)"
SUPPORT_DIR="/Library/Application Support/FanFanLocal"
SERVICE="com.huangyincan.fanfan.local.helper"
OLD_SERVICE="com.hoobnn.fanfan.helper"
APP="/Applications/fanfan.app"
HELPER="/Library/PrivilegedHelperTools/fanfan-local-smcd"
PLIST="/Library/LaunchDaemons/$SERVICE.plist"
OLD_APP="/Applications/.fanfan-before-local-$(date -u +%Y%m%dT%H%M%SZ).app"
WAS_LOCAL=0
MUTATING=0
APP_COPY_STARTED=0
PREVIOUS_FILES=("$HELPER" "$PLIST" "$SUPPORT_DIR/client.requirement" "$SUPPORT_DIR/manifest.json")
finish() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$MUTATING" -eq 1 ]; then
        set +e
        echo 'Installation failed; restoring the previous installation' >&2
        "$INSTALL_STAGE/fanfan-local-smcd" --restore-system
        /bin/launchctl bootout "system/$SERVICE" 2>/dev/null
        if [ "$APP_COPY_STARTED" -eq 1 ]; then
            /bin/rm -rf "$APP"
            if [ -d "$OLD_APP" ]; then /bin/mv "$OLD_APP" "$APP"; fi
        fi
        for index in "${!PREVIOUS_FILES[@]}"; do
            target="${PREVIOUS_FILES[$index]}"
            /bin/rm -f "$target"
            if [ -f "$INSTALL_STAGE/previous-$index" ]; then
                /bin/cp -p "$INSTALL_STAGE/previous-$index" "$target"
            fi
        done
        if [ "$WAS_LOCAL" -eq 1 ]; then
            /bin/launchctl enable "system/$SERVICE"
            /bin/launchctl bootstrap system "$PLIST"
            /bin/launchctl kickstart "system/$SERVICE"
        else
            /bin/launchctl enable "system/$OLD_SERVICE"
            /bin/launchctl bootstrap system "$APP/Contents/Library/LaunchDaemons/$OLD_SERVICE.plist" 2>/dev/null
            /bin/launchctl kickstart "system/$OLD_SERVICE" 2>/dev/null
        fi
        echo 'Previous files restored; reopen /Applications/fanfan.app' >&2
    fi
    /bin/rm -rf "$INSTALL_STAGE"
    exit "$status"
}
trap finish EXIT

# Stage under root ownership before validating, to avoid changing user-owned
# inputs between signature verification and installation.
/usr/bin/ditto "$PACKAGE_DIR/fanfan.app" "$INSTALL_STAGE/fanfan.app"
for file in fanfan-local-smcd manifest.json client.requirement rollback.sh; do
    /bin/cp "$PACKAGE_DIR/$file" "$INSTALL_STAGE/$file"
done
/usr/sbin/chown -R root:wheel "$INSTALL_STAGE"
/bin/chmod -R go-w "$INSTALL_STAGE"
/usr/bin/python3 - "$INSTALL_STAGE" <<'PY'
from pathlib import Path
import hashlib,json,plistlib,re,subprocess,sys
p=Path(sys.argv[1]); m=json.loads((p/'manifest.json').read_text())
assert m['flavor']=='local-hash-pinned' and m['version']=='1.8.2' and m['build']=='3301'
for key in ['appCodeHash','helperCodeHash']:
    assert re.fullmatch('[0-9a-f]{40}',m[key])
assert m['appRequirement']==f'identifier "com.hoobnn.fanfan" and cdhash H"{m["appCodeHash"]}"'
assert m['helperRequirement']==f'identifier "fanfan-local-smcd" and cdhash H"{m["helperCodeHash"]}"'
assert (p/'client.requirement').read_text().strip()==m['appRequirement']
assert hashlib.sha256((p/'fanfan-local-smcd').read_bytes()).hexdigest()==m['helperSHA256']
app=p/'fanfan.app'; info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.hoobnn.fanfan'
assert info['CFBundleShortVersionString']=='1.8.2' and info['CFBundleVersion']=='3301'
assert info['FanFanBuildFlavor']=='local-hash-pinned' and 'SUFeedURL' not in info
assert not (app/'Contents/Frameworks/Sparkle.framework').exists()
for target,req in [(app,m['appRequirement']),(p/'fanfan-local-smcd',m['helperRequirement'])]:
    subprocess.run(['codesign','--verify','--deep','--strict','-R',req,str(target)],check=True)
    result=subprocess.run(['codesign','-d','--verbose=4',str(target)],capture_output=True,text=True,check=True)
    assert re.search(r'flags=.*runtime',result.stderr), 'Hardened runtime missing'
result=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True)
entitlements=plistlib.loads(result.stdout)
for key in ['com.apple.security.get-task-allow','com.apple.security.cs.disable-library-validation',
            'com.apple.security.cs.allow-dyld-environment-variables','com.apple.security.cs.allow-unsigned-executable-memory']:
    assert not entitlements.get(key,False),key
print('Verified exact peer hashes, signed resources, hardened runtime, and disabled upstream updates')
PY

/usr/bin/install -d -o root -g wheel -m 755 "$SUPPORT_DIR" "$SUPPORT_DIR/backups" /Library/PrivilegedHelperTools
BACKUP="$SUPPORT_DIR/backups/official-$(date -u +%Y%m%dT%H%M%SZ).zip"
if [ -d "$APP" ]; then
    FLAVOR="$(/usr/libexec/PlistBuddy -c 'Print :FanFanBuildFlavor' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$FLAVOR" = local-hash-pinned ]; then
        WAS_LOCAL=1
        test -f "$SUPPORT_DIR/last-backup"
    else
        /usr/bin/codesign --verify --deep --strict "$APP"
        /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$BACKUP"
        /bin/chmod 600 "$BACKUP"
        printf '%s\n' "$BACKUP" > "$SUPPORT_DIR/last-backup"
    fi
fi
/usr/bin/install -o root -g wheel -m 755 "$INSTALL_STAGE/rollback.sh" "$SUPPORT_DIR/rollback.sh"
for index in "${!PREVIOUS_FILES[@]}"; do
    if [ -f "${PREVIOUS_FILES[$index]}" ]; then
        /bin/cp -p "${PREVIOUS_FILES[$index]}" "$INSTALL_STAGE/previous-$index"
    fi
done

# Stop the old app, then verify a firmware handoff before replacing its files.
# SIGTERM closes its XPC connection; the helper also has a 10-second fail-safe.
/usr/bin/pkill -TERM -x fanfan 2>/dev/null || true
for attempt in {1..30}; do
    if ! /usr/bin/pgrep -x fanfan >/dev/null; then break; fi
    /bin/sleep 0.2
done
if /usr/bin/pgrep -x fanfan >/dev/null; then
    echo "App did not exit; installation stopped before replacement" >&2; exit 1
fi
"$INSTALL_STAGE/fanfan-local-smcd" --restore-system
MUTATING=1
/bin/launchctl disable "system/$OLD_SERVICE" 2>/dev/null || true
/bin/launchctl bootout "system/$OLD_SERVICE" 2>/dev/null || true
/bin/launchctl bootout "system/$SERVICE" 2>/dev/null || true

# Keep a same-volume copy until the replacement has been copied successfully.
if [ -d "$APP" ]; then /bin/mv "$APP" "$OLD_APP"; fi
APP_COPY_STARTED=1
/usr/bin/ditto "$INSTALL_STAGE/fanfan.app" "$APP"
/usr/sbin/chown -R root:wheel "$APP"
/bin/chmod -R go-w "$APP"
/usr/bin/install -o root -g wheel -m 755 "$INSTALL_STAGE/fanfan-local-smcd" "$HELPER"
/usr/bin/install -o root -g wheel -m 644 "$INSTALL_STAGE/client.requirement" "$SUPPORT_DIR/client.requirement"
/usr/bin/install -o root -g wheel -m 644 "$INSTALL_STAGE/manifest.json" "$SUPPORT_DIR/manifest.json"
/usr/bin/python3 - "$PLIST" "$HELPER" "$SERVICE" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump({'Label':sys.argv[3], 'ProgramArguments':[sys.argv[2]],
        'MachServices':{sys.argv[3]:True}, 'RunAtLoad':True,'KeepAlive':True,
        'StandardErrorPath':'/var/log/fanfan-local-smcd.err','ProcessType':'Interactive'},f)
PY
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/bin/launchctl enable "system/$SERVICE"
/bin/launchctl bootstrap system "$PLIST"
/bin/launchctl kickstart "system/$SERVICE"
/usr/bin/codesign --verify --deep --strict "$APP"
"$HELPER" --status
/bin/launchctl print "system/$SERVICE" | /usr/bin/grep -q 'state = running'

# The zip is the durable rollback copy; do not leave another launchable app
# with the same bundle identifier where Launch Services can select it.
if [ -d "$OLD_APP" ]; then /bin/rm -rf "$OLD_APP"; fi
MUTATING=0
echo "INSTALL_OK: FanFan 1.8.2 本机版 (3301)"
echo "Rollback: sudo /bin/bash '$SUPPORT_DIR/rollback.sh'"
