import os

// Structured logging for the real-time (broadcast-gated) app-blocking
// feature, filterable via Console.app / Xcode's device console with
// subsystem "com.slowth.realtimeshield" — fixed and not derived from
// Bundle.main, since the host app and its extensions have different
// bundle IDs but need to show up under one filter.
enum RTLog {
    static let sampleHandler = Logger(subsystem: "com.slowth.realtimeshield", category: "SampleHandler")
    static let shield = Logger(subsystem: "com.slowth.realtimeshield", category: "ManagedSettingsApplier")
    static let shieldAction = Logger(subsystem: "com.slowth.realtimeshield", category: "ShieldAction")
    static let shieldConfig = Logger(subsystem: "com.slowth.realtimeshield", category: "ShieldConfig")
    static let appState = Logger(subsystem: "com.slowth.realtimeshield", category: "AppState")
    static let activityMonitor = Logger(subsystem: "com.slowth.realtimeshield", category: "DeviceActivity")
}
