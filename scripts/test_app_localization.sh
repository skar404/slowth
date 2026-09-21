#!/bin/bash
set -euo pipefail

# Pass a built macOS app so the test uses real compiled .strings resources.
app_resources="${1:?Usage: test_app_localization.sh /path/to/Slowth.app}/Contents/Resources"
test_root=$(mktemp -d /tmp/slowth-localization.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
fixture_app="$test_root/LanguageChecks.app"
mkdir -p "$fixture_app/Contents/MacOS" "$fixture_app/Contents/Resources"
for localization in "$app_resources"/*.lproj; do
    cp -R "$localization" "$fixture_app/Contents/Resources/"
done
cat > "$fixture_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.slowth.localization.$(uuidgen)</string>
<key>CFBundleExecutable</key><string>LanguageChecks</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
EOF
xcrun swiftc -parse-as-library Shared/AppLocalization.swift WebExt/tests/AppLocalizationTests.swift \
    -o "$fixture_app/Contents/MacOS/LanguageChecks"
"$fixture_app/Contents/MacOS/LanguageChecks"
