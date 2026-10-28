#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d /tmp/slowth-welcome.XXXXXX)
trap 'rm -rf "$output"' EXIT
for mode in Release Debug; do
    flags=(-DRECORDING_SELECTION_TESTS -module-cache-path "$output/cache")
    if [[ "$mode" == Debug ]]; then flags+=(-DDEBUG); fi
    xcrun swiftc "${flags[@]}" Shared/AppLocalization.swift Shared/SharedStore.swift \
        Shared/RecordingAdmission.swift iOS/IOSWelcomeEligibility.swift tests/IOSWelcomeTests.swift \
        -o "$output/welcome"
    "$output/welcome"
done
# Verify the real ReplayKit entry points use the tested admission gate before
# touching persistent state, models, timers or frames, including rejected finish.
python3 - <<'PY'
from pathlib import Path
s = Path('RealtimeShield/SampleHandler.swift').read_text()
for name in ['broadcastStarted', 'broadcastResumed']:
    body = s.split('override func ' + name, 1)[1].split('override func ', 1)[0]
    gate = body.index('guard admitRecording() else { return }')
    for effect in ['SoftYouTubeActivityMonitoring.stop()', 'SharedStore.setBroadcastActive(true)',
                   'loadClassifier()', 'IOSPauseCoordinator.beginRecordingGrace()', 'startRestWatchdog()']:
        assert gate < body.index(effect), (name, effect)
body = s.split('override func broadcastFinished', 1)[1].split('override func ', 1)[0]
assert body.index('guard admission.admitted else { return }') < body.index('SharedStore.setBroadcastActive(false)')
body = s.split('override func processSampleBuffer', 1)[1]
assert body.index('guard admission.active,') < body.index('let sharedState = SharedStore.snapshot()')
print('ReplayKit admission wiring checks passed')
PY
