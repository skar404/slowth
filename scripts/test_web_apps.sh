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
import json,sys
inventory=json.load(sys.stdin)["devices"]
for runtime in sorted(inventory, reverse=True):
    if ".iOS-" not in runtime: continue
    version=tuple(int(v) for v in runtime.split(".iOS-")[1].split("-"))
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
