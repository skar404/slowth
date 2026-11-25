#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d /tmp/slowth-web-apps.XXXXXX)
owned_device=""
cleanup() {
    if [[ -n "$owned_device" ]]; then
        xcrun simctl shutdown "$owned_device" >/dev/null 2>&1 || true
        xcrun simctl delete "$owned_device" >/dev/null 2>&1 || true
    fi
    # Restore the normal local project after the isolated browser-test build.
    if [[ -f "$output/webapps-project.json" ]]; then xcodegen generate >/dev/null; fi
    rm -rf "$output"
}
trap cleanup EXIT
phase() {
    local label="$1" started=$SECONDS
    shift
    printf '\n[webapps] %s started (%s)\n' "$label" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    "$@"
    printf '[webapps] %s completed in %ss\n' "$label" "$((SECONDS - started))"
}
phase 'Compile contracts' xcrun swiftc Shared/AppLocalization.swift Shared/WebSettingsNotifications.swift \
  Shared/SharedStore.swift Shared/WebAppService.swift Shared/WebAppProfile.swift \
  Shared/WebAppsRouter.swift Extension/NativeExtensionMessageHandler.swift \
  WebExt/tests/WebAppsTests.swift -o "$output/contracts"
phase 'Run contracts' "$output/contracts"
if [[ "${1:-}" == "--simulator" ]]; then
    device="${2:-auto}"
    if [[ "$device" == auto ]]; then
        device=$(xcrun simctl list devices available --json | python3 -c '
import json,re,subprocess,sys,uuid
inventory=json.load(sys.stdin)["devices"]
sdk=tuple(map(int,sys.argv[1].split(".")))
# Device-specific runtimes can end in a model suffix, e.g. iOS-27-2-iPhone19-4.
runtimes=[]
for runtime in inventory:
    match=re.search(r"\.iOS-(\d+(?:-\d+)*)", runtime)
    if match:
        version=tuple(map(int, match[1].split("-")))
        # Prefer the SDK-matching runtime over newer device-specific beta images.
        runtimes.append((version == sdk, match.end() == len(runtime), version, runtime))
for _,_,version,runtime in sorted(runtimes, reverse=True):
    if version < (18,4): continue
    for device in inventory[runtime]:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            # Never reuse an image-provided device or an existing developer simulator.
            # Its website stores and process state are outside this test run.
            name="Slowth WebKit " + str(uuid.uuid4())[:8]
            created=subprocess.check_output(["xcrun", "simctl", "create", name,
                device["deviceTypeIdentifier"], runtime], text=True).strip()
            print(created); sys.exit(0)
sys.exit("An available iPhone simulator with iOS 18.4+ is required")' "$(xcrun --sdk iphonesimulator --show-sdk-version)")
        owned_device="$device"
    fi
    printf '[webapps] Simulator: %s (owned: %s)\n' "$device" "${owned_device:-no}"
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
    build_args=(-project Unscroll.xcodeproj -scheme 'Web apps tests'
      -destination "platform=iOS Simulator,id=$device"
      -derivedDataPath build/webapps-tests CODE_SIGNING_ALLOWED=NO)
    phase 'Build for testing' xcodebuild "${build_args[@]}" build-for-testing
    # A fresh simulator can fail to launch the test host while first-boot work is
    # still running. Wait explicitly and report this separately from XCTest time.
    phase 'Boot simulator' python3 - "$device" <<'PYTHON'
import subprocess, sys
try:
    subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b", "-d"],
                   check=True, timeout=180)
except subprocess.TimeoutExpired:
    sys.exit("Simulator did not finish booting within 180 seconds; tests were not started")
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
PYTHON
    phase 'Run hosted tests' xcodebuild "${build_args[@]}" \
      -parallel-testing-enabled NO -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 120 \
      -maximum-test-execution-time-allowance 120 test-without-building
fi
