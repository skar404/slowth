#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
module=iOS/Blocking
for mode in Release Debug; do
    flags=(-DPAUSE_TESTS)
    if [[ "$mode" == Debug ]]; then flags+=(-DDEBUG); fi
    swiftc "${flags[@]}" Shared/PauseOnlyApps.swift tests/IOSPauses/ShieldNavigationBindingsTests.swift -o "$output/shield-navigation"
    "$output/shield-navigation"
    swiftc "${flags[@]}" Shared/PauseTargetDisplay.swift tests/IOSPauses/PauseTargetDisplayTests.swift -o "$output/target-display"
    "$output/target-display"
    swiftc "${flags[@]}" -DSHIELD_NOTIFICATION_TESTS iOS/ShieldNotifications/ShieldNotification.swift tests/IOSPauses/ShieldNotificationTests.swift -o "$output/shield-notification"
    "$output/shield-notification"
    swiftc "${flags[@]}" -DRECORDING_HEALTH_TESTS Shared/RecordingHealthProbe.swift tests/IOSPauses/RecordingHealthProbeTests.swift -o "$output/recording-health"
    "$output/recording-health"
    base=("$module/IOSPauseLedger.swift" "$module/BlockingDatabase.swift" "$module/BlockingRules.swift")
    swiftc "${flags[@]}" "${base[@]}" iOS/IOSShieldPromptPresentation.swift tests/IOSPauses/ShieldPromptPresentationTests.swift -o "$output/shield-prompt"
    "$output/shield-prompt"
    for suite in Ledger DetectionRest Database; do
        swiftc "${flags[@]}" "${base[@]}" "tests/IOSPauses/${suite}Tests.swift" -o "$output/$suite"
        "$output/$suite"
    done
    swiftc "${flags[@]}" "$module/BlockingRules.swift" tests/IOSPauses/BlockingRulesTests.swift -o "$output/rules"
    "$output/rules"
    swiftc "${flags[@]}" -DPAUSE_COORDINATOR_TESTS "${base[@]}" \
        "$module/IOSPauseCoordinator.swift" "$module/BlockingClock.swift" \
        "$module/BlockingStorage.swift" "$module/BlockingShield.swift" "$module/BlockingCoordinator.swift" "$module/BlockingPauseMonitor.swift" \
        tests/IOSPauses/CoordinatorTests.swift -o "$output/coordinator"
    "$output/coordinator"
done
