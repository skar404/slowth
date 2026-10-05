#!/bin/bash
set -euo pipefail

# GitHub runner images move; fail rather than silently selecting another Xcode.
test "$(xcodebuild -version)" = $'Xcode 26.2\nBuild version 17C52'
tool_dir="${RUNNER_TEMP:?}/slowth-tools"
mkdir -p "$tool_dir"
curl --fail --location --silent --show-error --retry 3 \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip \
  --output "$tool_dir/xcodegen.zip"
echo "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  $tool_dir/xcodegen.zip" | shasum -a 256 -c -
unzip -q "$tool_dir/xcodegen.zip" -d "$tool_dir"
echo "$tool_dir/xcodegen/bin" >> "${GITHUB_PATH:?}"
test "$("$tool_dir/xcodegen/bin/xcodegen" --version)" = 'Version: 2.46.0'
