#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d /tmp/slowth-web-apps.XXXXXX)
cleanup() {
    # Restore the normal local project after the isolated browser-test build.
    if [[ -f "$output/webapps-project.json" ]]; then xcodegen generate >/dev/null; fi
    rm -rf "$output"
}
trap cleanup EXIT
xcrun swiftc Shared/AppLocalization.swift Shared/WebSettingsNotifications.swift \
  Shared/SharedStore.swift Shared/WebAppService.swift Shared/WebAppProfile.swift \
  Shared/WebAppsRouter.swift Extension/NativeExtensionMessageHandler.swift \
  WebExt/tests/WebAppsTests.swift -o "$output/contracts"
"$output/contracts"
if [[ "${1:-}" == "--simulator" ]]; then
    device="${2:-auto}"
    if [[ "$device" == auto ]]; then
        device=$(xcrun simctl list devices available --json | python3 -c '
import json,re,sys
inventory=json.load(sys.stdin)["devices"]
# Device-specific runtimes can end in a model suffix, e.g. iOS-27-2-iPhone19-4.
runtimes=[]
for runtime in inventory:
    match=re.search(r"\.iOS-(\d+(?:-\d+)*)", runtime)
    if match: runtimes.append((tuple(map(int, match[1].split("-"))), runtime))
for version,runtime in sorted(runtimes, reverse=True):
    if version < (18,4): continue
    for device in inventory[runtime]:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            print(device["udid"]); sys.exit(0)
sys.exit("An available iPhone simulator with iOS 18.4+ is required")')
    fi
    # Browser tests do not exercise ML inference. XcodeGen optional sources still
    # produce CoreML build references when packages are absent in a clean checkout.
    xcodegen dump --type json --no-env > "$output/project.json"
    python3 - "$output" <<'PYTHON'
import json,sys
from pathlib import Path
folder=Path(sys.argv[1])
spec=json.loads((folder / "project.json").read_text())
for target in spec["targets"].values():
    target["sources"]=[source for source in target.get("sources", [])
        if not (isinstance(source, dict) and source.get("optional")
                and source.get("path", "").startswith("Models/"))]
(folder / "webapps-project.json").write_text(json.dumps(spec))
PYTHON
    xcodegen generate --spec "$output/webapps-project.json" --project-root "$PWD" --project "$PWD"
    xcodebuild -project Unscroll.xcodeproj -scheme 'Web apps tests' \
      -destination "platform=iOS Simulator,id=$device" \
      -derivedDataPath build/webapps-tests CODE_SIGNING_ALLOWED=NO test
fi
