// Compiles the production coordinator on macOS with only OS boundaries replaced.
import Foundation

enum CoordinatorTestEnvironment {
    static var now = IOSPauseClock(wall: 1_792_000_000, continuous: 1000, boot: "test")
    static var databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static var inExtension = false
    static var foreground = false
    static var generation: String?
}
// Replace process identity at the OS boundary so production Broadcast detection runs.
enum Bundle {
    struct Identity { var bundleIdentifier: String? }
    static var main = Identity(bundleIdentifier: "test.Slowth")
}
struct FamilyActivitySelection: Codable {
    var applicationTokens: Set<String> = []
    var categoryTokens: Set<String> = []
    var webDomainTokens: Set<String> = []
}
enum AuthorizationStatus { case approved, approvedWithDataAccess, denied }
final class AuthorizationCenter {
    static let shared = AuthorizationCenter()
    var authorizationStatus = AuthorizationStatus.approved
}
enum IOSProtectionAuthorization {
    static func approved(_ status: AuthorizationStatus) -> Bool {
        status == .approved || status == .approvedWithDataAccess
    }
}
final class ManagedSettingsStore {
    struct Name: Hashable { let rawValue: String; init(_ value: String) { rawValue = value } }
    enum Categories { case specific(Set<String>) }
    final class Shield { var applications: Set<String>?; var applicationCategories: Categories? }
    static var stores: [Name: Shield] = [:]
    let shield: Shield
    init(named name: Name) {
        if let existing = Self.stores[name] { shield = existing }
        else { shield = Shield(); Self.stores[name] = shield }
    }
}
struct DeviceActivityName { let rawValue: String; init(_ value: String) { rawValue = value } }
struct DeviceActivitySchedule { let intervalStart: DateComponents; let intervalEnd: DateComponents; let repeats: Bool }
struct DeviceActivityCenter {
    static var monitored = Set<String>()
    func startMonitoring(_ name: DeviceActivityName, during: DeviceActivitySchedule) throws { Self.monitored.insert(name.rawValue) }
    func stopMonitoring(_ names: [DeviceActivityName]) { for name in names { Self.monitored.remove(name.rawValue) } }
}
struct SiteFlags { var dictionary = ["shorts": true] }
struct SharedState {
    var isStrictModeActive = false
    var broadcastActive = true
    var realtimeShieldEnabled = true
    var realtimeYouTubeBlockingEnabled = true
    var realtimeInstagramBlockingEnabled = true
    var realtimeFacebookBlockingEnabled = false
    var realtimeXBlockingEnabled = false
    var softYouTubeBlockingEnabled = false
    var youtubeShieldRestoreDeferred = false
    var youtubeSelectionData: Data?
    var instagramSelectionData: Data?
    var facebookSelectionData: Data?
    var xSelectionData: Data?
    var toggles = ["youtube": SiteFlags()]
}
enum SharedStore {
    static var state = SharedState()
    static var pausesAllowedInStrictMode = true
    static func snapshot() -> SharedState { state }
    static func isSlowthAppForeground() -> Bool { CoordinatorTestEnvironment.foreground }
    static func setSlowthAppForeground(_ value: Bool) { CoordinatorTestEnvironment.foreground = value }
    static func softYouTubeMonitorGeneration() -> String? { CoordinatorTestEnvironment.generation }
    static func setYouTubeShieldRestoreDeferred(_ value: Bool) { state.youtubeShieldRestoreDeferred = value }
    static func syncRealtimeShieldAuthorization(_ status: AuthorizationStatus) {
        state.realtimeShieldEnabled = IOSProtectionAuthorization.approved(status)
    }
}
enum AppGroup {
    static let identifier = "slowth.coordinator.tests." + UUID().uuidString
    static let defaults = UserDefaults(suiteName: identifier)!
}
enum PauseOnlyApps {
    static let targets = ["tiktok", "snapchat"]
    static var selections: [String: Data] = [:]
    static func contains(_ target: String) -> Bool { targets.contains(target) }
    static func data(_ target: String) -> Data? { selections[target] }
    static func selection(_ target: String) -> FamilyActivitySelection? {
        data(target).flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
    }
}
enum GroupedApps {
    static var rules = GroupedContentRules()
    static var exceptions: [GroupedContentException<String>] = []
    static func blockedSelection(for kinds: Set<GroupedContentRules.Kind>) -> FamilyActivitySelection? {
        guard var selected = selection else { return nil }
        selected.applicationTokens = rules.blockedTokens(from: selected.applicationTokens, kinds: kinds, exceptions: exceptions)
        return selected.applicationTokens.isEmpty ? nil : selected
    }
    static var isEnabled = false
    static var data: Data?
    static var selection: FamilyActivitySelection? {
        data.flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
    }
    static var softSelection: FamilyActivitySelection? {
        guard SharedStore.state.softYouTubeBlockingEnabled else { return nil }
        return SharedStore.state.youtubeSelectionData.flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
    }
}
enum DeviceActivityEvent { struct Name { let rawValue: String; init(_ value: String) { rawValue = value } } }
enum SoftYouTubeActivityMonitoring {
    static var fails = false
    static func start() -> Bool {
        if fails { return false }
        CoordinatorTestEnvironment.generation = UUID().uuidString
        return true
    }
    static func stop() { CoordinatorTestEnvironment.generation = nil }
    static func generation(for activity: DeviceActivityName, event: DeviceActivityEvent.Name) -> String? {
        activity.rawValue == event.rawValue ? activity.rawValue : nil
    }
    static func stop(activity: DeviceActivityName, generation: String) {
        if CoordinatorTestEnvironment.generation == generation { CoordinatorTestEnvironment.generation = nil }
    }
}
enum ManagedSettingsApplier {
    enum Surface: String { case apps, youtube, instagram, facebook, x, tiktok, snapchat }
    static func apply(surface: Surface, selection: FamilyActivitySelection?) {
        _ = IOSPauseCoordinator.intercept(target: surface.rawValue, requested: selection)
    }
    static func clear(surface: Surface) { apply(surface: surface, selection: nil) }
}
actor IOSPauseLiveActivity {
    static let shared = IOSPauseLiveActivity()
    func synchronize() {}
}
enum DebugMode { static var isEnabled = true }

@main enum CoordinatorChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); AppGroup.defaults.removePersistentDomain(forName: AppGroup.identifier) }
        func selected(_ token: String) throws -> Data { try JSONEncoder().encode(FamilyActivitySelection(applicationTokens: [token])) }
        let youtube = try selected("youtube-original"), instagram = try selected("instagram-original")
        func reset() {
            GroupedApps.rules = GroupedContentRules()
            GroupedApps.exceptions = []
            GroupedApps.isEnabled = false
            GroupedApps.data = nil
            CoordinatorTestEnvironment.databaseURL = root.appendingPathComponent(UUID().uuidString)
            CoordinatorTestEnvironment.now = .init(wall: 1_792_000_000, continuous: 1000, boot: "test")
            CoordinatorTestEnvironment.inExtension = false
            Bundle.main.bundleIdentifier = "test.Slowth"
            CoordinatorTestEnvironment.foreground = false
            CoordinatorTestEnvironment.generation = nil
            SoftYouTubeActivityMonitoring.fails = false
            SharedStore.state = SharedState(youtubeSelectionData: youtube, instagramSelectionData: instagram)
            AuthorizationCenter.shared.authorizationStatus = .approved
            ManagedSettingsStore.stores = [:]
            PauseOnlyApps.selections = [:]
            AppGroup.defaults.removePersistentDomain(forName: AppGroup.identifier)
        }
        func advance(_ seconds: Double) {
            CoordinatorTestEnvironment.now.wall += seconds
            CoordinatorTestEnvironment.now.continuous += seconds
        }
        func shield(_ target: String = "youtube") -> Set<String>? {
            ManagedSettingsStore(named: .init("RealtimeShield." + target)).shield.applications
        }
        func check(_ condition: @autoclosure () throws -> Bool) throws { let result = try condition(); assert(result) }
        func expectFailure(_ action: () throws -> Void) {
            do { try action(); fatalError("Expected rejection") } catch {}
        }
        #if DEBUG
        reset()
        try IOSPauseCoordinator.requestRest(target: "youtube")
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
        try IOSPauseCoordinator.startApplication(target: "instagram", id: "debug-reset-pause")
        try BlockingStorage.database().transaction { ledger in
            ledger.detectionRestProgress = [
                "youtube": .init(day: "2026-10-27", count: 7),
                "instagram": .init(day: "2026-10-27", count: 5)]
            ledger.detectionRestZone = "UTC"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let beforeReset = try IOSPauseCoordinator.presentationSnapshot()
        let beforeShields = ManagedSettingsStore.stores.mapValues { $0.applications }
        DebugMode.isEnabled = false
        expectFailure { try IOSPauseCoordinator.resetRestProgressForDebug() }
        try check(encoder.encode(IOSPauseCoordinator.presentationSnapshot()) == encoder.encode(beforeReset))
        DebugMode.isEnabled = true
        try IOSPauseCoordinator.resetRestProgressForDebug()
        let afterReset = try IOSPauseCoordinator.presentationSnapshot()
        var expectedReset = beforeReset
        expectedReset.detectionRestProgress = nil
        expectedReset.detectionRestZone = nil
        try check(encoder.encode(afterReset) == encoder.encode(expectedReset))
        assert(ManagedSettingsStore.stores.mapValues { $0.applications } == beforeShields)
        var nextRest = afterReset
        nextRest.invalidateBinding("youtube")
        nextRest.requestDetectionRest(target: "youtube", selection: youtube,
            now: CoordinatorTestEnvironment.now, fromShieldAction: false, currentZone: "UTC")
        assert(nextRest.detectionRests?["youtube"]?.effectiveDuration == 5)
        print("PASS: Debug reset clears only progression; release gates, shields, pause, quota and rest clocks unchanged")
        #endif

        reset()
        try IOSPauseCoordinator.beginRecordingGrace()
        advance(6)
        try IOSPauseCoordinator.startApplication(target: "youtube", id: "pause-1")
        let disposition = try IOSPauseCoordinator.requestRest(target: "youtube", expectedSelection: youtube)
        assert(disposition == .suppressedByPause && shield() == nil)
        try IOSPauseCoordinator.finish(id: "pause-1")
        try check(try IOSPauseCoordinator.returnToApplicationAfterRest(target: "youtube") == false)
        try IOSPauseCoordinator.requestRest(target: "youtube", prioritize: true)
        let rests = try IOSPauseCoordinator.openRests()
        assert(rests.count == 1 && rests[0].released == nil && rests[0].remaining(CoordinatorTestEnvironment.now) == 5)
        let notificationBefore = try Data(contentsOf: CoordinatorTestEnvironment.databaseURL)
        for _ in 0..<3 { try check(try IOSPauseCoordinator.hasRestForNotification(target: "youtube")) }
        try check(try !IOSPauseCoordinator.hasRestForNotification(target: "unknown"))
        try check(try Data(contentsOf: CoordinatorTestEnvironment.databaseURL) == notificationBefore)
        advance(5)
        try check(try !IOSPauseCoordinator.hasRestForNotification(target: "youtube"))
        try check(try Data(contentsOf: CoordinatorTestEnvironment.databaseURL) == notificationBefore)
        try IOSPauseCoordinator.advanceRests()
        assert(shield() == nil)
        let released = try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!.released!
        advance(1)
        try IOSPauseCoordinator.advanceRests()
        try check(try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!.released!.continuous == released.continuous)
        print("PASS: pause suppression, stale cycle recovery, fixed rest deadline")

        // The Shield write starts the durable clock, before any host opening.
        reset()
        try IOSPauseCoordinator.requestRest(target: "youtube")
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
        let cycle = try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!
        assert(cycle.started?.continuous == 1000 && shield() == ["youtube-original"])
        try check(try IOSPauseCoordinator.openRests()[0].remaining(CoordinatorTestEnvironment.now) == 5)
        advance(2)
        try check(try IOSPauseCoordinator.openRests()[0].remaining(CoordinatorTestEnvironment.now) > 2.99)
        try IOSPauseCoordinator.requestRest(target: "youtube")
        try IOSPauseCoordinator.requestRest(target: "youtube", prioritize: true)
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
        let repeated = try IOSPauseCoordinator.openRests()[0]
        assert(repeated.id == cycle.id && repeated.started?.continuous == 1000)
        advance(3)
        try IOSPauseCoordinator.advanceRests()
        assert(shield() == nil)
        try check(try IOSPauseCoordinator.openRests().isEmpty)
        assert(IOSPauseCoordinator.restGrants()["youtube"]?.graceRemaining(CoordinatorTestEnvironment.now) == 3)
        print("PASS: Shield starts progressive rest; opening, detection and repeated writes preserve deadline")

        for stopped in [false, true] {
            reset()
            try IOSPauseCoordinator.requestRest(target: "youtube")
            _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
            // No host calls: the watchdog reloads persisted state after background/lock.
            advance(5)
            if stopped { SharedStore.state.broadcastActive = false }
            try IOSPauseCoordinator.advanceRests()
            assert((shield() != nil) == stopped)
            try check(try IOSPauseCoordinator.openRests().isEmpty)
        }
        reset()
        try IOSPauseCoordinator.requestRest(target: "youtube")
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
        try IOSPauseCoordinator.setInferenceFailure(true, state: SharedStore.state, target: "youtube")
        advance(5)
        try IOSPauseCoordinator.advanceRests()
        assert(shield() == ["youtube-original"] && IOSPauseCoordinator.restGrants()["youtube"] == nil)
        try check(try IOSPauseCoordinator.openRests().isEmpty)
        print("PASS: no-host watchdog completion; stopped recording and faults retain protection")

        // Old records start on Shield application or host opening, never on a read.
        for useShield in [false, true] {
            reset()
            try BlockingStorage.database().transaction { ledger in
                ledger.detectionRests = ["youtube": IOSDetectionRest(target: "youtube", selection: youtube)]
            }
            try check(try IOSPauseCoordinator.hasRestForNotification(target: "youtube"))
            try IOSPauseCoordinator.advanceRests()
            try check(try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!.started == nil)
            if useShield {
                _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
            } else { _ = try IOSPauseCoordinator.openRests() }
            advance(40)
            try check(try IOSPauseCoordinator.openRests()[0].remaining(CoordinatorTestEnvironment.now) == 20)
            CoordinatorTestEnvironment.now = .init(wall: 1_792_000_100, continuous: 10, boot: "reboot")
            try IOSPauseCoordinator.advanceRests()
            try check(try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!.started?.continuous == 10)
            advance(40)
            try check(try IOSPauseCoordinator.openRests()[0].remaining(CoordinatorTestEnvironment.now) == 20)
            advance(20)
            try IOSPauseCoordinator.advanceRests()
            try check(try IOSPauseCoordinator.openRests().isEmpty)
        }
        print("PASS: legacy start fallback and full minute after reboot without host")

        // QA fault injection: vary independent runtime gates after a real Shield start.
        for bits in 0..<128 {
            func flag(_ bit: Int) -> Bool { bits & (1 << bit) != 0 }
            reset()
            try IOSPauseCoordinator.requestRest(target: "youtube")
            _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
            if flag(5) { try IOSPauseCoordinator.startApplication(target: "youtube", id: "matrix-pause") }
            if flag(3) { try IOSPauseCoordinator.setInferenceFailure(true, state: SharedStore.state, target: "youtube") }
            SharedStore.state.broadcastActive = flag(0)
            AuthorizationCenter.shared.authorizationStatus = flag(1) ? .approved : .denied
            CoordinatorTestEnvironment.inExtension = flag(2)
            if flag(4) { SharedStore.state.youtubeSelectionData = try selected("matrix-replacement") }
            SharedStore.state.realtimeYouTubeBlockingEnabled = !flag(6)
            advance(5)
            try IOSPauseCoordinator.advanceRests()
            let result = try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!
            let shouldRelease = flag(0) && (flag(1) || flag(2)) && !flag(3) && !flag(4) && !flag(5) && !flag(6)
            precondition(result.completed == true, "Unfinished matrix case \(bits)")
            precondition((result.released != nil) == shouldRelease, "Release gate matrix case \(bits)")
            if shouldRelease { precondition(shield() == nil, "Shield not cleared in case \(bits)") }
            else if flag(3) && !flag(4) && !flag(5) && !flag(6) {
                precondition(shield() == ["youtube-original"], "Fault bypass in case \(bits)")
            }
        }
        print("PASS: 128 runtime gate combinations (recording/auth/extension/fault/binding/pause/enabled)")

        reset()
        try IOSPauseCoordinator.requestRest(target: "youtube")
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
        advance(2)
        try IOSPauseCoordinator.requestRest(target: "instagram")
        _ = IOSPauseCoordinator.intercept(target: "instagram", requested: .init(applicationTokens: ["instagram-original"]))
        advance(2.999)
        try IOSPauseCoordinator.advanceRests()
        assert(shield() != nil && shield("instagram") != nil)
        advance(0.002)
        try IOSPauseCoordinator.advanceRests()
        assert(shield() == nil && shield("instagram") != nil)
        let firstGrant = try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!
        advance(2.999)
        try IOSPauseCoordinator.advanceRests()
        assert(firstGrant.graceRemaining(CoordinatorTestEnvironment.now) > 0)
        advance(0.002)
        assert(firstGrant.graceRemaining(CoordinatorTestEnvironment.now) == 0)
        try IOSPauseCoordinator.requestRest(target: "youtube")
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: .init(applicationTokens: ["youtube-original"]))
        let nextCycle = try IOSPauseCoordinator.presentationSnapshot().detectionRests!["youtube"]!
        assert(nextCycle.id != firstGrant.id && nextCycle.remaining(CoordinatorTestEnvironment.now) == 5)
        advance(0.5)
        try IOSPauseCoordinator.advanceRests()
        assert(shield() != nil && shield("instagram") == nil)
        print("PASS: 5s/3s boundary checks, independent services and next detection cycle")

        // A fault wins over startup grace, released rests, direct clears and restore.
        reset()
        try IOSPauseCoordinator.beginRecordingGrace()
        try IOSPauseCoordinator.setInferenceFailure(true, state: SharedStore.state, target: "youtube")
        assert(IOSPauseCoordinator.restGrants()["instagram"] != nil)
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: nil)
        assert(shield() == ["youtube-original"])
        assert(IOSPauseCoordinator.restGrants()["youtube"] == nil)
        try check(try IOSPauseCoordinator.returnToApplicationAfterRest(target: "youtube") == false)
        expectFailure { try IOSPauseCoordinator.requestRest(target: "youtube", prioritize: true) }
        try IOSPauseCoordinator.startApplication(target: "youtube", id: "fault-pause")
        assert(shield() == nil)
        try IOSPauseCoordinator.finish(id: "fault-pause")
        assert(shield() == ["youtube-original"])
        try IOSPauseCoordinator.setInferenceFailure(false, state: SharedStore.state)
        assert(!IOSPauseCoordinator.inferenceUnavailable("youtube"))
        print("PASS: classifier fault cannot be cleared by stale grants; explicit pause still works")

        reset()
        try IOSPauseCoordinator.requestRest(target: "youtube")
        _ = try IOSPauseCoordinator.openRests()
        advance(0.2)
        try IOSPauseCoordinator.startApplication(target: "youtube", id: "rest-pause")
        advance(0.2)
        try check(try IOSPauseCoordinator.openRests().isEmpty)
        try IOSPauseCoordinator.finish(id: "rest-pause")
        try check(try IOSPauseCoordinator.openRests()[0].remaining(CoordinatorTestEnvironment.now) > 4.59)
        print("PASS: existing rest survives an ordinary pause")

        reset()
        try IOSPauseCoordinator.beginRecordingGrace()
        try IOSPauseCoordinator.startApplication(target: "youtube", id: "replace")
        let replacement = try selected("replacement")
        SharedStore.state.youtubeSelectionData = replacement
        try IOSPauseCoordinator.selectionDidChange(target: "youtube", previousSelection: youtube)
        assert(shield() == ["replacement"])
        let after = try IOSPauseCoordinator.presentationSnapshot()
        assert(after.lease == nil && after.detectionRests?["youtube"] == nil)
        assert(!DeviceActivityCenter.monitored.contains("slowth.pause.replace"))
        expectFailure { try IOSPauseCoordinator.requestRest(target: "youtube", expectedSelection: youtube) }
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: nil)
        assert(shield() == nil)
        SharedStore.state.instagramSelectionData = replacement
        assert(IOSPauseCoordinator.hasSelectionConflict("youtube", state: SharedStore.state))
        assert(!IOSPauseCoordinator.canStartApplicationPause(target: "youtube"))
        print("PASS: replacement retires old token/lease/rest; conflicting tokens cannot pause")

        reset()
        AuthorizationCenter.shared.authorizationStatus = .approvedWithDataAccess
        assert(IOSPauseCoordinator.canStartApplicationPause(target: "youtube"))
        AuthorizationCenter.shared.authorizationStatus = .denied
        assert(!IOSPauseCoordinator.canStartApplicationPause(target: "youtube"))
        CoordinatorTestEnvironment.inExtension = true
        assert(IOSPauseCoordinator.protectionAuthorized(SharedStore.state))
        SharedStore.state.realtimeShieldEnabled = false
        assert(!IOSPauseCoordinator.protectionAuthorized(SharedStore.state))
        print("PASS: host authorization and extension synchronized authorization")

        reset()
        try IOSPauseCoordinator.startApplication(target: "youtube", id: "watchdog")
        advance(181)
        // No frames and no DeviceActivity callback: watchdog reconciliation suffices.
        try IOSPauseCoordinator.advanceRests()
        try check(try IOSPauseCoordinator.presentationSnapshot().lease == nil)
        assert(shield() == ["youtube-original"])
        print("PASS: watchdog restores an expired pause without video frames")

        // Freeze the stopped-recorder policy before moving production rules.
        for soft in [false, true] {
            reset()
            SharedStore.state.broadcastActive = false
            SharedStore.state.softYouTubeBlockingEnabled = soft
            SharedStore.state.youtubeShieldRestoreDeferred = soft
            try IOSPauseCoordinator.startApplication(target: "youtube", id: "stopped")
            assert(shield() == nil)
            try IOSPauseCoordinator.finish(id: "stopped")
            assert(shield() == (soft ? nil : ["youtube-original"]))
        }
        for target in PauseOnlyApps.targets {
            reset()
            SharedStore.state.broadcastActive = false
            PauseOnlyApps.selections[target] = try selected(target)
            try IOSPauseCoordinator.startApplication(target: target, id: target)
            assert(shield(target) == nil)
            try IOSPauseCoordinator.finish(id: target)
            assert(shield(target) == [target])
        }
        reset()
        SharedStore.state.isStrictModeActive = true
        SharedStore.pausesAllowedInStrictMode = false
        expectFailure { try IOSPauseCoordinator.startApplication(target: "youtube", id: "strict") }
        SharedStore.pausesAllowedInStrictMode = true
        // An unreadable ledger must not turn a clear request into permission.
        CoordinatorTestEnvironment.databaseURL = root
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: nil)
        assert(shield() == ["youtube-original"])
        print("PASS: normal/soft stopped recording, pause-only services, Strict and storage failure")

        reset()
        SharedStore.state.broadcastActive = false
        SharedStore.state.softYouTubeBlockingEnabled = true
        BlockingCoordinator.hostOpened(facebookSupported: true, xSupported: true)
        assert(shield() == nil && SharedStore.state.youtubeShieldRestoreDeferred)
        BlockingCoordinator.hostClosed(facebookSupported: true, xSupported: true)
        let oldGeneration = CoordinatorTestEnvironment.generation!
        BlockingCoordinator.hostOpened(facebookSupported: true, xSupported: true)
        BlockingCoordinator.usageThreshold(.init(oldGeneration), activity: .init(oldGeneration))
        assert(shield() == nil)
        BlockingCoordinator.hostClosed(facebookSupported: true, xSupported: true)
        let currentGeneration = CoordinatorTestEnvironment.generation!
        BlockingCoordinator.usageThreshold(.init(oldGeneration), activity: .init(oldGeneration))
        assert(CoordinatorTestEnvironment.generation == currentGeneration)
        assert(shield() == nil)
        SharedStore.state.broadcastActive = true
        BlockingCoordinator.usageThreshold(.init(currentGeneration), activity: .init(currentGeneration))
        assert(shield() == nil)
        SharedStore.state.broadcastActive = false
        SoftYouTubeActivityMonitoring.fails = true
        BlockingCoordinator.hostClosed(facebookSupported: true, xSupported: true)
        assert(shield() == ["youtube-original"] && !SharedStore.state.youtubeShieldRestoreDeferred)
        SoftYouTubeActivityMonitoring.fails = false
        BlockingCoordinator.hostOpened(facebookSupported: true, xSupported: true)
        BlockingCoordinator.hostClosed(facebookSupported: true, xSupported: true)
        let threshold = CoordinatorTestEnvironment.generation!
        BlockingCoordinator.usageThreshold(.init(threshold), activity: .init(threshold))
        assert(shield() == ["youtube-original"] && !SharedStore.state.youtubeShieldRestoreDeferred)
        BlockingCoordinator.usageThreshold(.init(threshold), activity: .init(threshold))
        assert(shield() == ["youtube-original"])
        SharedStore.state.softYouTubeBlockingEnabled = false
        BlockingCoordinator.hostOpened(facebookSupported: true, xSupported: true)
        assert(shield() == ["youtube-original"])
        print("PASS: soft host/threshold sequences, stale generations, recording race, failure and duplicate callback")

        // Replay SampleHandler's stop -> deferred permission -> Shield write as Broadcast.
        func stopBroadcast(soft: Bool = true, monitorFails: Bool = false) -> Bool {
            SharedStore.state.softYouTubeBlockingEnabled = soft
            Bundle.main.bundleIdentifier = "test.Slowth.Broadcast"
            CoordinatorTestEnvironment.inExtension = true
            SoftYouTubeActivityMonitoring.fails = monitorFails
            SharedStore.state.broadcastActive = false
            let latch = BlockingCoordinator.recordingStopped(SharedStore.snapshot())
            ManagedSettingsApplier.apply(surface: .youtube,
                selection: latch ? .init(applicationTokens: ["youtube-original"]) : nil)
            return latch
        }
        reset()
        // Start with an existing Shield to prove this request actually removes it.
        ManagedSettingsApplier.apply(surface: .youtube, selection: .init(applicationTokens: ["youtube-original"]))
        assert(!stopBroadcast())
        assert(SharedStore.state.youtubeShieldRestoreDeferred && CoordinatorTestEnvironment.generation != nil)
        assert(AppGroup.defaults.object(forKey: "pause.runtime.youtube.shield") as? Bool == false)
        assert(shield() == nil, "Broadcast clear must honor the newly granted soft deferral")
        let stoppedGeneration = CoordinatorTestEnvironment.generation!
        Bundle.main.bundleIdentifier = "test.Slowth.ActivityMonitor"
        BlockingCoordinator.usageThreshold(.init(stoppedGeneration), activity: .init(stoppedGeneration))
        Bundle.main.bundleIdentifier = "test.Slowth.Broadcast"
        ManagedSettingsApplier.clear(surface: .youtube)
        assert(shield() == ["youtube-original"] && !SharedStore.state.youtubeShieldRestoreDeferred)

        for soft in [false, true] {
            reset()
            assert(stopBroadcast(soft: soft, monitorFails: soft))
            ManagedSettingsApplier.clear(surface: .youtube)
            assert(shield() == ["youtube-original"] && !SharedStore.state.youtubeShieldRestoreDeferred)
        }
        reset()
        try IOSPauseCoordinator.requestRest(target: "youtube")
        assert(!stopBroadcast())
        assert(shield() == ["youtube-original"], "Unfinished rest wins over soft deferral")
        try IOSPauseCoordinator.startApplication(target: "youtube", id: "soft-rest-pause")
        ManagedSettingsApplier.clear(surface: .youtube)
        assert(shield() == nil, "Active user pause wins over unfinished rest")
        try IOSPauseCoordinator.finish(id: "soft-rest-pause")
        ManagedSettingsApplier.clear(surface: .youtube)
        assert(shield() == ["youtube-original"])

        reset()
        assert(!stopBroadcast())
        SharedStore.state.realtimeFacebookBlockingEnabled = true
        SharedStore.state.realtimeXBlockingEnabled = true
        SharedStore.state.facebookSelectionData = try selected("facebook")
        SharedStore.state.xSelectionData = try selected("x")
        for target in PauseOnlyApps.targets { PauseOnlyApps.selections[target] = try selected(target) }
        for target in IOSPauseCoordinator.apps where target != "youtube" {
            _ = IOSPauseCoordinator.intercept(target: target, requested: nil)
            assert(shield(target) != nil, "YouTube deferral must not open other apps")
        }
        for reopenHost in [false, true] {
            reset()
            assert(!stopBroadcast())
            let stale = CoordinatorTestEnvironment.generation!
            if reopenHost {
                Bundle.main.bundleIdentifier = "test.Slowth"
                CoordinatorTestEnvironment.inExtension = false
                BlockingCoordinator.hostOpened(facebookSupported: true, xSupported: true)
            } else {
                // Same monitor cancellation and recording-state transition as broadcastStarted.
                SoftYouTubeActivityMonitoring.stop()
                SharedStore.state.broadcastActive = true
                try IOSPauseCoordinator.beginRecordingGrace()
            }
            Bundle.main.bundleIdentifier = "test.Slowth.ActivityMonitor"
            BlockingCoordinator.usageThreshold(.init(stale), activity: .init(stale))
            assert(shield() == nil && CoordinatorTestEnvironment.generation == nil)
        }
        print("PASS: Broadcast stop deferral, threshold revocation, monitor failure, rest/pause priority, other apps and stale callbacks")

        var bindings = IOSRecorderBindings()
        let selections = ["youtube": youtube, "instagram": instagram]
        assert(bindings.update(selections, pausedTarget: nil, revision: 0) == ["youtube", "instagram"])
        assert(bindings.update(selections, pausedTarget: nil, revision: 0).isEmpty)
        assert(bindings.update(selections, pausedTarget: "youtube", revision: 1).contains("youtube"))
        assert(bindings.update(selections, pausedTarget: "instagram", revision: 2).contains("youtube"))
        assert(bindings.update(selections, pausedTarget: nil, revision: 3).contains("instagram"))
        // Start + end between watchdog polls still resets evidence by revision.
        assert(bindings.update(selections, pausedTarget: nil, revision: 5) == ["youtube", "instagram"])
        assert(bindings.update(["youtube": replacement, "instagram": instagram], pausedTarget: nil, revision: 5) == ["youtube"])
        reset()
        let oldRevision = try IOSPauseCoordinator.recordingPolicy().revision
        try IOSPauseCoordinator.startApplication(target: "youtube", id: "race")
        try IOSPauseCoordinator.finish(id: "race")
        expectFailure { try IOSPauseCoordinator.requestRest(target: "youtube", expectedSelection: youtube, expectedRevision: oldRevision) }
        print("PASS: pause/switch/binding transitions reset evidence; in-flight stale detection rejected")

        reset()
        GroupedApps.isEnabled = true
        let group = FamilyActivitySelection(applicationTokens: ["youtube-original", "instagram-original", "arbitrary-app"])
        GroupedApps.data = try JSONEncoder().encode(group)
        assert(IOSPauseCoordinator.apps == ["apps"])
        SharedStore.state.broadcastActive = false
        BlockingCoordinator.enforceAtRest(SharedStore.state, facebookSupported: true, xSupported: true)
        assert(shield("group") == group.applicationTokens)
        try IOSPauseCoordinator.startApplication(target: "apps", id: "group-pause")
        assert(shield("group") == nil && shield("youtube") == nil)
        try check(IOSPauseCoordinator.applicationSwitchTargets(try IOSPauseCoordinator.snapshot(), state: SharedStore.state, now: CoordinatorTestEnvironment.now).isEmpty)
        try IOSPauseCoordinator.finish(id: "group-pause")
        assert(shield("group") == group.applicationTokens)
        SharedStore.state.broadcastActive = true
        try IOSPauseCoordinator.beginRecordingGrace()
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: nil)
        assert(shield("group") == nil)
        advance(6)
        try IOSPauseCoordinator.requestRest(target: "apps")
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: group)
        assert(shield("group") == group.applicationTokens)
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: nil)
        assert(shield("group") == group.applicationTokens, "Another service's clear cannot bypass the group rest")
        advance(6)
        try IOSPauseCoordinator.advanceRests()
        assert(shield("group") == nil)
        try IOSPauseCoordinator.setInferenceFailure(true, state: SharedStore.state)
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: nil)
        assert(shield("group") == group.applicationTokens)
        try IOSPauseCoordinator.startApplication(target: "apps", id: "group-fault-pause")
        assert(shield("group") == nil)
        try IOSPauseCoordinator.finish(id: "group-fault-pause")
        assert(shield("group") == group.applicationTokens)
        print("PASS: multi-app group shares pause, detection rest, grace and inference-failure protection")

        reset()
        GroupedApps.isEnabled = true
        GroupedApps.data = try JSONEncoder().encode(group)
        SharedStore.state.broadcastActive = false
        SharedStore.state.softYouTubeBlockingEnabled = true
        BlockingCoordinator.hostOpened(facebookSupported: true, xSupported: true)
        assert(shield("group") == ["instagram-original", "arbitrary-app"] && shield("youtube") == nil)
        BlockingCoordinator.hostClosed(facebookSupported: true, xSupported: true)
        let groupGeneration = CoordinatorTestEnvironment.generation!
        BlockingCoordinator.usageThreshold(.init(groupGeneration), activity: .init(groupGeneration))
        assert(shield("youtube") == ["youtube-original"])
        assert(shield("group") == ["instagram-original", "arbitrary-app"])
        try IOSPauseCoordinator.startApplication(target: "apps", id: "group-soft-pause")
        assert(shield("group") == nil && shield("youtube") == nil)
        ManagedSettingsApplier.apply(surface: .youtube, selection: .init(applicationTokens: ["youtube-original"]))
        assert(shield("youtube") == nil, "Soft monitor cannot override the shared pause")
        try IOSPauseCoordinator.finish(id: "group-soft-pause")
        assert(shield("group") == ["instagram-original", "arbitrary-app"] && shield("youtube") == ["youtube-original"])
        SharedStore.state.broadcastActive = true
        try IOSPauseCoordinator.requestRest(target: "apps")
        SharedStore.state.broadcastActive = false
        SharedStore.state.youtubeShieldRestoreDeferred = true
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: group)
        assert(shield("youtube") == ["youtube-original"], "Pending group rest wins over soft deferral")
        let boundGroup = GroupedApps.data
        let replacementGroup = FamilyActivitySelection(applicationTokens: ["replacement-app"])
        GroupedApps.data = try JSONEncoder().encode(replacementGroup)
        try IOSPauseCoordinator.selectionDidChange(target: "apps", previousSelection: boundGroup)
        assert(shield("group") == ["replacement-app"] && shield("youtube") == nil)
        SharedStore.state.broadcastActive = true
        expectFailure { try IOSPauseCoordinator.requestRest(target: "apps", expectedSelection: boundGroup) }
        GroupedApps.data = try JSONEncoder().encode(FamilyActivitySelection())
        try IOSPauseCoordinator.selectionDidChange(target: "apps", previousSelection: try JSONEncoder().encode(replacementGroup))
        assert(shield("group") == nil && shield("youtube") == nil)
        print("PASS: soft YouTube is separate at rest, but shares the group's pause and detection-rest priority")

        // Content exceptions protect opaque tokens, independently of inferred app identity.
        reset()
        GroupedApps.isEnabled = true
        GroupedApps.data = try JSONEncoder().encode(group)
        GroupedApps.exceptions = [
            .init(token: "youtube-original", allowShortVideos: true, allowStories: true),
            .init(token: "instagram-original", allowShortVideos: false, allowStories: true),
            .init(token: "arbitrary-app", allowShortVideos: true, allowStories: false)]
        SharedStore.state.softYouTubeBlockingEnabled = true
        let accepted = try IOSPauseCoordinator.requestRest(target: "apps", contentKinds: [.shortVideos])
        assert(accepted == .accepted)
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: group)
        assert(shield("group") == ["instagram-original"] && shield("youtube") == nil)
        // Host soft-mode writes must respect the persisted content subset too.
        _ = IOSPauseCoordinator.intercept(target: "youtube", requested: nil)
        assert(shield("youtube") == nil)
        let firstRest = try IOSPauseCoordinator.presentationSnapshot().detectionRests!["apps"]!
        advance(1)
        try IOSPauseCoordinator.startApplication(target: "apps", id: "exception-pause")
        assert(shield("group") == nil && shield("youtube") == nil)
        try IOSPauseCoordinator.finish(id: "exception-pause")
        assert(shield("group") == ["instagram-original"] && shield("youtube") == nil)
        try IOSPauseCoordinator.requestRest(target: "apps", contentKinds: [.stories])
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: nil)
        assert(shield("group") == ["instagram-original", "arbitrary-app"] && shield("youtube") == nil)
        let mergedRest = try IOSPauseCoordinator.presentationSnapshot().detectionRests!["apps"]!
        assert(mergedRest.id == firstRest.id && mergedRest.started?.continuous == firstRest.started?.continuous)
        assert(mergedRest.contentKinds == [.shortVideos, .stories])
        // Codable persistence preserves the full binding and the narrower blocked subset.
        let restoredRest = try JSONDecoder().decode(IOSDetectionRest.self, from: JSONEncoder().encode(mergedRest))
        assert(restoredRest.selection == GroupedApps.data && restoredRest.blockedSelection == mergedRest.blockedSelection)
        SharedStore.state.broadcastActive = false
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: group)
        assert(shield("group") == ["instagram-original", "arbitrary-app"] && shield("youtube") == ["youtube-original"])
        SharedStore.state.broadcastActive = true
        try IOSPauseCoordinator.setInferenceFailure(true, state: SharedStore.state)
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: nil)
        assert(shield("youtube") == ["youtube-original"], "An inference fault remains fail-closed")
        print("PASS: token exceptions survive pause/host writes/persistence; mixed detections union subsets without extending rest")

        reset()
        GroupedApps.isEnabled = true
        GroupedApps.data = try JSONEncoder().encode(group)
        GroupedApps.exceptions = group.applicationTokens.map { .init(token: $0, allowShortVideos: true, allowStories: true) }
        let ignored = try IOSPauseCoordinator.requestRest(target: "apps", contentKinds: [.shortVideos, .stories])
        assert(ignored == .noBlockedApplications)
        let emptyRestLedger = try IOSPauseCoordinator.presentationSnapshot()
        assert(emptyRestLedger.detectionRests?["apps"] == nil && emptyRestLedger.detectionRestProgress?["apps"] == nil)
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: nil)
        assert(shield("group") == nil && shield("youtube") == nil)
        GroupedApps.exceptions = []
        try IOSPauseCoordinator.requestRest(target: "apps", contentKinds: [.stories])
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: group)
        SharedStore.state.broadcastActive = false
        GroupedApps.exceptions = group.applicationTokens.map { .init(token: $0, allowShortVideos: false, allowStories: true) }
        try IOSPauseCoordinator.refreshGroupedExceptions()
        try check(IOSPauseCoordinator.presentationSnapshot().detectionRests?["apps"] == nil)
        print("PASS: all-exempt detection creates no rest/progression; stopped-recording edits retire an empty subset")

        reset()
        GroupedApps.isEnabled = true
        GroupedApps.data = try JSONEncoder().encode(group)
        GroupedApps.exceptions = [.init(token: "arbitrary-app", allowShortVideos: true, allowStories: true)]
        try IOSPauseCoordinator.requestRest(target: "apps", contentKinds: [.shortVideos])
        _ = IOSPauseCoordinator.intercept(target: "apps", requested: group)
        try IOSPauseCoordinator.startApplication(target: "apps", id: "completed-exception-rest")
        advance(6)
        try IOSPauseCoordinator.advanceRests()
        try check(IOSPauseCoordinator.presentationSnapshot().detectionRests?["apps"]?.completed == true)
        try IOSPauseCoordinator.finish(id: "completed-exception-rest")
        assert(shield("group") == ["youtube-original", "instagram-original"], "Completed but unreleased rest must not briefly block an exempt app")
        try IOSPauseCoordinator.advanceRests()
        assert(shield("group") == nil)
        print("PASS: exception subset retained when a rest completes during a user pause")
    }
}
