#!/usr/bin/env python3
"""Build an isolated, ad-hoc signed edition with mutually pinned XPC peers.

The upstream sources and contributor branch are not rewritten. The root daemon
loads the app's exact CodeDirectory requirement from a root-owned policy file;
the app pins the daemon's exact hash. No certificate trust settings are changed.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = ROOT / "local-support"
build_root = ROOT / "build.noindex"
build_root.mkdir(exist_ok=True)
stage = Path(tempfile.mkdtemp(prefix="local-", dir=build_root))
source = stage / "source"
source.mkdir()
for name in ("fanfan", "fanfan.xcodeproj", "tools"):
    shutil.copytree(ROOT / name, source / name)
dist = ROOT / "local-dist"
dist.mkdir(exist_ok=True)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def code_hash(path):
    result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                            capture_output=True, text=True, check=True)
    match = re.search(r"^CDHash=([a-f0-9]{40})$", result.stderr, re.M)
    if not match:
        raise RuntimeError("Missing CodeDirectory hash: " + str(path))
    return match.group(1)


helper_dir = source / "tools/fanfan-smcd"
for name in ("client-policy.h", "helper-cli.h"):
    shutil.copy2(SUPPORT / name, helper_dir / name)
helper_source = helper_dir / "fanfan-smcd.c"
text = helper_source.read_text()
text = text.replace('"com.hoobnn.fanfan.helper"', '"com.huangyincan.fanfan.local.helper"')
text = re.sub(r"#define CLIENT_REQUIREMENT \\\n.*?\n/\* Pre-1\.4", """static char g_local_client_requirement[512];
#define CLIENT_REQUIREMENT g_local_client_requirement
#include "client-policy.h"
/* Pre-1.4""", text, count=1, flags=re.S)
assert "#define CLIENT_REQUIREMENT g_local_client_requirement" in text
text = text.replace("int main(void)\n{", """#include "helper-cli.h"

int main(int argc, char **argv)
{
    int cli_result = local_cli(argc, argv);
    if (cli_result >= 0) return cli_result;
    if (load_local_client_policy("/Library/Application Support/FanFanLocal/client.requirement",
                                 g_local_client_requirement, sizeof(g_local_client_requirement)) != 0) {
        fprintf(stderr, "fanfan-local: missing or unsafe root-owned client policy; refusing to start\\n");
        return 1;
    }
""")
text = text.replace("    remove_legacy_daemon();", "    /* Local installation leaves official/legacy daemons untouched. */")
helper_source.write_text(text)
helper = dist / "fanfan-local-smcd"
run("xcrun", "clang", "-Wall", "-Wextra", "-O2", "-arch", "arm64",
    "-mmacosx-version-min=26.0", "-o", str(helper), str(helper_source),
    "-framework", "IOKit", "-framework", "CoreFoundation")
run("codesign", "--force", "--sign", "-", "--options", "runtime",
    "--identifier", "fanfan-local-smcd", str(helper))
helper_hash = code_hash(helper)
helper_requirement = f'identifier "fanfan-local-smcd" and cdhash H"{helper_hash}"'
shutil.copy2(helper, source / "fanfan/Resources/fanfan-smcd")

client_file = source / "fanfan/Core/SMCDaemonClient.swift"
text = client_file.read_text().replace('"com.hoobnn.fanfan.helper"', '"com.huangyincan.fanfan.local.helper"')
text = re.sub(r'(nonisolated private static let daemonRequirement =\n)\s+"[^\n]+"',
              lambda match: match[1] + "        " + json.dumps(helper_requirement), text, count=1)
assert helper_hash in text
text = text.replace("enum SMCDaemonClient {", """enum SMCDaemonClient {
    nonisolated static func localCommandResponse(_ command: String) -> String? {
        send(command)
    }
""", 1)
client_file.write_text(text)
for name in ("PermissionsManager.swift", "AppUpdater.swift"):
    shutil.copy2(SUPPORT / name, source / "fanfan/Core" / name)

project = source / "fanfan.xcodeproj/project.pbxproj"
text = project.read_text()
for section in ("XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency"):
    text = re.sub(r"/\* Begin " + section + r" section \*/.*?/\* End " + section + r" section \*/", "", text, flags=re.S)
sparkle_ids = ("5A0B1E012FB8000000000001", "5A0B1E022FB8000000000002", "5A0B1E032FB8000000000003")
text = "\n".join(line for line in text.split("\n") if not any(key in line for key in sparkle_ids))
assert "Sparkle" not in text
project.write_text(text)
run("plutil", "-lint", str(project))
info_file = source / "fanfan/Info.plist"
info = plistlib.loads(info_file.read_bytes())
for key in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks"):
    info.pop(key, None)
info["CFBundleDisplayName"] = "FanFan 本机版"
info["FanFanBuildFlavor"] = "local-hash-pinned"
info_file.write_bytes(plistlib.dumps(info))

app_file = source / "fanfan/App/fanfanApp.swift"
text = app_file.read_text()
marker = "    func applicationDidFinishLaunching(_ notification: Notification) {\n"
assert marker in text
text = text.replace(marker, marker + (SUPPORT / "app-cli.swift.txt").read_text(), 1)
app_file.write_text(text)
popover = source / "fanfan/UI/Views/PopoverView.swift"
text = popover.read_text().replace('return "v\\(v ?? "1.0")"', 'return "v\\(v ?? "1.0") · 本机版"')
popover.write_text(text)
settings = source / "fanfan/UI/Views/SettingsView.swift"
text = settings.read_text().replace('rowLabel("settings.auto_check_updates")\n            }',
                                    'rowLabel("settings.auto_check_updates")\n            }\n            .disabled(true)')
settings.write_text(text)

run("xcodebuild", "-project", str(source / "fanfan.xcodeproj"), "-scheme", "fanfan",
    "-configuration", "Release", "-derivedDataPath", str(stage / "derived"),
    "-destination", "generic/platform=macOS", "CODE_SIGNING_ALLOWED=NO",
    "DEVELOPMENT_TEAM=", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
    "ENABLE_CODE_COVERAGE=NO", "CLANG_COVERAGE_MAPPING=NO",
    "GCC_GENERATE_TEST_COVERAGE_FILES=NO", "GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO",
    "MARKETING_VERSION=1.8.2", "CURRENT_PROJECT_VERSION=3302", "build")
app = stage / "derived/Build/Products/Release/fanfan.app"
assert not (app / "Contents/Frameworks/Sparkle.framework").exists()
run("codesign", "--force", "--sign", "-", "--options", "runtime",
    "--entitlements", str(source / "fanfan/Resources/fanfan.entitlements"), str(app))
run("codesign", "--verify", "--deep", "--strict", str(app))
app_hash = code_hash(app)
app_requirement = f'identifier "com.hoobnn.fanfan" and cdhash H"{app_hash}"'
run("codesign", "--verify", "--strict", "-R", "=" + app_requirement, str(app))
run("codesign", "--verify", "--strict", "-R", "=" + helper_requirement, str(helper))
for requirement in (app_requirement, helper_requirement):
    bad = subprocess.run(["codesign", "--verify", "-R", "=" + requirement, "/usr/bin/true"], capture_output=True)
    assert bad.returncode != 0, "An unrelated binary matched the peer pin"

run("ditto", str(app), str(dist / "fanfan.app"))
(dist / "client.requirement").write_text(app_requirement + "\n")
manifest = {
    "version": "1.8.2", "build": "3302", "flavor": "local-hash-pinned",
    "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "appRequirement": app_requirement, "helperRequirement": helper_requirement,
    "appCodeHash": app_hash, "helperCodeHash": helper_hash,
    "helperSHA256": hashlib.sha256(helper.read_bytes()).hexdigest(),
}
(dist / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
run("xcrun", "clang", "-fblocks", "-arch", "arm64", "-mmacosx-version-min=26.0", "-o",
    str(dist / "unauthorized-probe"), str(SUPPORT / "unauthorized-probe.c"))
run("codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier",
    "com.hoobnn.fanfan", str(dist / "unauthorized-probe"))
for name in ("install.sh", "rollback.sh", "launchd-service.sh"):
    shutil.copy2(SUPPORT / name, dist / name)
archive = ROOT / "fanfan-local-arm64.tar.gz"
run("tar", "-czf", str(archive), "-C", str(dist), ".")
print("Local build verified:", archive)
