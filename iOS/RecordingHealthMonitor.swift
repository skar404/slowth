import UIKit

@MainActor
enum RecordingHealthMonitor {
    static func run(onRecovery: () -> Void) async {
        var probe: RecordingHealthStore.Probe?
        var window = RecordingHealthWindow()
        var nextCheck: TimeInterval = 0
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let active = UIApplication.shared.applicationState == .active
            guard window.observe(active: active, now: now) else {
                probe = nil
                nextCheck = 0
                continue
            }
            guard now >= nextCheck else { continue }
            do {
                let store = try RecordingHealthStore.shared()
                if probe == nil { probe = try store.begin(now: now) }
                guard let pending = probe else { nextCheck = now + 2; continue }
                let result = try store.poll(pending, now: now, recover: {
                    var diagnostics = SharedStore.snapshot().realtimeShieldDiagnostics
                    diagnostics.modelStatus = "interrupted"
                    diagnostics.lastClassifierError = "Recording extension did not respond to the foreground health check. Restart recording."
                    diagnostics.updatedAt = Date()
                    SharedStore.setRealtimeShieldDiagnostics(diagnostics)
                    onRecovery()
                })
                if result != .waiting {
                    RTLog.appState.notice("Recording health: \(result.rawValue, privacy: .public)")
                    probe = nil
                    nextCheck = now + 15
                }
            } catch {
                // Failure to read shared storage is not evidence of recorder death.
                RTLog.appState.error("Recording health storage unavailable: \(String(describing: error), privacy: .public)")
                probe = nil
                nextCheck = now + 5
            }
        }
    }
}
