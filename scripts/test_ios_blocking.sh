#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
module=iOS/Blocking
for mode in Release Debug; do
    flags=(-DPAUSE_TESTS)
    if [[ "$mode" == Debug ]]; then flags+=(-DDEBUG); fi
    swiftc "${flags[@]}" Shared/PauseTargetDisplay.swift tests/IOSPauses/PauseTargetDisplayTests.swift -o "$output/target-display"
    "$output/target-display"
    base=("$module/IOSPauseLedger.swift" "$module/BlockingDatabase.swift" "$module/BlockingRules.swift")
    for suite in Ledger DetectionRest; do
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
