#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d /tmp/slowth-web-apps.XXXXXX)
trap 'rm -rf "$output"' EXIT
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
    xcodegen generate
    xcodebuild -project Unscroll.xcodeproj -scheme 'Web apps tests' \
      -destination "platform=iOS Simulator,id=$device" \
      -derivedDataPath build/webapps-tests CODE_SIGNING_ALLOWED=NO test
fi
