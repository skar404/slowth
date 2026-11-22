#if DEBUG && os(iOS)
import SwiftUI
import FamilyControls
import ManagedSettings

/// Sanitized inspection of this app's configuration, not the system's effective
/// policy. Export counts/policies only; the probe's opaque receipt stays local.
enum ManagedSettingsDiagnostics {
    private enum ProbeError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case let .unavailable(reason): return reason }
        }
    }
    private static let probeKey = "debug.managedSettings.oneAppProbe"
    private static let otherAppsName = ManagedSettingsStore.Name("Slowth.WebsiteProbe.OtherApps")
    private struct ProbeReceipt: Codable {
        let applications: Set<ApplicationToken>
        let selection: Data
        let token: ApplicationToken
    }
    static var probeActive: Bool { AppGroup.defaults.data(forKey: probeKey) != nil }
    // The regular Debug settings sheet remains read-only. The probe requires a
    // dedicated launch that does not construct AppState and its coordinator.
    static var probeAvailable: Bool {
        if #available(iOS 26.5, *) {
            return ProcessInfo.processInfo.arguments.contains("--diagnose-managed-settings")
        }
        return false
    }
    static var probeBlocked: Bool {
        !(ManagedSettingsStore(named: .init("RealtimeShield.group")).shield.applications?.isEmpty ?? true)
    }

    private static func checkProbeConditions() throws {
        let state = SharedStore.snapshot()
        guard probeAvailable, GroupedApps.isEnabled else { throw ProbeError.unavailable("Requires the isolated diagnostic launch and grouped apps.") }
        guard !state.broadcastActive, !state.isStrictModeActive else { throw ProbeError.unavailable("Recording or Strict mode is active.") }
        let ledger: IOSPauseLedger
        do { ledger = try IOSPauseCoordinator.presentationSnapshot() }
        catch { throw ProbeError.unavailable("Cannot read the pause ledger: \(error)") }
        guard ledger.lease == nil else { throw ProbeError.unavailable("A pause lease exists.") }
        guard !(ledger.detectionRests ?? [:]).values.contains(where: { $0.released == nil && $0.completed != true })
        else { throw ProbeError.unavailable("A detection rest is pending.") }
    }

    /// Diagnostic only. User preferences/ledger are unchanged. A durable receipt
    /// restores the exact shield when the probe ends or Slowth next launches.
    static func startProbe(token: ApplicationToken) throws {
        try checkProbeConditions()
        guard !probeActive,
              let selection = GroupedApps.data else { throw IOSPauseError.unavailable }
        guard #available(iOS 26.5, *) else { throw IOSPauseError.unavailable }
        let groupName = ManagedSettingsStore.Name("RealtimeShield.group")
        for name in ManagedSettingsStore.stores.union([.default]) {
            let store = ManagedSettingsStore(named: name)
            guard store.shield.applicationCategories == nil, store.shield.webDomains == nil,
                  store.shield.webDomainCategories == nil, store.webContent.blockedByFilter == nil,
                  store.application.blockedApplications == nil,
                  name == groupName || (store.shield.applications?.isEmpty ?? true)
            else { throw IOSPauseError.unavailable }
        }
        let store = ManagedSettingsStore(named: groupName)
        guard let applications = store.shield.applications, applications.contains(token) else { throw IOSPauseError.unavailable }
        let receipt = ProbeReceipt(applications: applications, selection: selection, token: token)
        AppGroup.defaults.set(try JSONEncoder().encode(receipt), forKey: probeKey)
        AppGroup.defaults.synchronize()
        // Preserve every other application's protection while isolating this one.
        let others = applications.subtracting([token])
        ManagedSettingsStore(named: otherAppsName).shield.applications = others.isEmpty ? nil : others
        // The entire minimal reproducer: a single application token, no websites.
        store.shield.applications = [token]
    }

    static func setProbeBlocked(_ blocked: Bool) throws {
        try checkProbeConditions()
        guard let data = AppGroup.defaults.data(forKey: probeKey) else {
            throw IOSPauseError.unavailable
        }
        let receipt = try JSONDecoder().decode(ProbeReceipt.self, from: data)
        let store = ManagedSettingsStore(named: .init("RealtimeShield.group"))
        let applications = store.shield.applications ?? []
        // Abort if a coordinator/extension has replaced the isolated setup.
        guard receipt.selection == GroupedApps.data else { throw ProbeError.unavailable("The saved app selection changed.") }
        guard applications.isEmpty || applications == [receipt.token] else { throw ProbeError.unavailable("The isolated app-token set changed.") }
        guard (ManagedSettingsStore(named: otherAppsName).shield.applications ?? []) == receipt.applications.subtracting([receipt.token])
        else { throw ProbeError.unavailable("The other-app token set changed.") }
        store.shield.applications = blocked ? [receipt.token] : nil
    }

    static func armWebProbe(_ selection: FamilyActivitySelection) throws {
        try checkProbeConditions()
        guard probeActive, selection.applicationTokens.isEmpty, selection.categoryTokens.isEmpty,
              !selection.webDomainTokens.isEmpty else { throw IOSPauseError.unavailable }
        try WebsiteShieldProbe.arm(selection.webDomainTokens)
    }

    static func restoreProbe() throws {
        guard let data = AppGroup.defaults.data(forKey: probeKey) else {
            WebsiteShieldProbe.clear()
            return
        }
        let receipt = try JSONDecoder().decode(ProbeReceipt.self, from: data)
        // Never restore an obsolete selection or override a new recorder session.
        if receipt.selection == GroupedApps.data && !SharedStore.snapshot().broadcastActive {
            ManagedSettingsStore(named: .init("RealtimeShield.group")).shield.applications = receipt.applications
        }
        ManagedSettingsStore(named: otherAppsName).shield.applications = nil
        WebsiteShieldProbe.clear()
        AppGroup.defaults.removeObject(forKey: probeKey)
        AppGroup.defaults.synchronize()
    }

    static func report() -> [String: Any] {
        let names: Set<ManagedSettingsStore.Name>
        let complete: Bool
        if #available(iOS 26.5, *) {
            names = ManagedSettingsStore.stores.union([.default])
            complete = true
        } else {
            names = Set((["UnscrollShield"] + ["apps", "group", "youtube", "instagram", "facebook", "x", "tiktok", "snapchat"]
                .map { "RealtimeShield." + $0 }).map { ManagedSettingsStore.Name($0) }).union([.default])
            complete = false
        }
        let state = SharedStore.snapshot()
        let stores = names.sorted { $0.rawValue < $1.rawValue }.map { name -> [String: Any] in
            let store = ManagedSettingsStore(named: name)
            var row: [String: Any] = [
                "name": name.rawValue,
                "applications": store.shield.applications?.count as Any? ?? NSNull(),
                "applicationCategories": categories(store.shield.applicationCategories),
                "webDomains": store.shield.webDomains?.count as Any? ?? NSNull(),
                "webDomainCategories": categories(store.shield.webDomainCategories),
                "webFilter": filter(store.webContent.blockedByFilter),
                "blockedApplications": store.application.blockedApplications?.count as Any? ?? NSNull()
            ]
            if #available(iOS 26.5, *) { row["active"] = store.isActive }
            return row
        }
        return ["capturedAt": ISO8601DateFormatter().string(from: Date()),
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "completeStoreEnumeration": complete,
                "recording": state.broadcastActive,
                "groupedApps": GroupedApps.isEnabled,
                "selectedApps": GroupedApps.selection?.applicationTokens.count ?? 0,
                "strict": state.isStrictModeActive,
                "oneAppProbe": probeActive,
                "websiteProbe": WebsiteShieldProbe.report,
                "stores": stores]
    }

    private static func categories<Activity>(_ policy: ShieldSettings.ActivityCategoryPolicy<Activity>?) -> [String: Any] {
        guard let policy else { return ["policy": "unset"] }
        switch policy {
        case .none: return ["policy": "none"]
        case let .all(except: exceptions): return ["policy": "all", "exceptions": exceptions.count]
        case let .specific(categories, except: exceptions):
            return ["policy": "specific", "categories": categories.count, "exceptions": exceptions.count]
        @unknown default: return ["policy": "unknown"]
        }
    }

    private static func filter(_ policy: WebContentSettings.FilterPolicy?) -> [String: Any] {
        guard let policy else { return ["policy": "unset"] }
        switch policy {
        case .none: return ["policy": "none"]
        case let .all(except: exceptions): return ["policy": "all", "exceptions": exceptions.count]
        case let .specific(domains): return ["policy": "specific", "domains": domains.count]
        case let .auto(domains, except: exceptions):
            return ["policy": "auto", "domains": domains.count, "exceptions": exceptions.count]
        @unknown default: return ["policy": "unknown"]
        }
    }

    static func export() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: report(), options: [.prettyPrinted, .sortedKeys])
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("ManagedSettingsDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
        return String(decoding: data, as: UTF8.self)
    }
}

struct ManagedSettingsDiagnosticsView: View {
    @State private var report = ""
    @State private var choosingProbe = false
    @State private var probeActive = ManagedSettingsDiagnostics.probeActive
    @State private var probeBlocked = true
    @State private var choosingWeb = false
    @State private var webSelection = FamilyActivitySelection()
    var body: some View {
        NavigationStack {
            ScrollView {
                if probeActive {
                    Button("Choose website shield…") { choosingWeb = true }.padding(.top)
                }
                Text(verbatim: report).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
            }
                .navigationTitle("Managed Settings")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Refresh") { refresh() } }
                    ToolbarItem(placement: .bottomBar) {
                        if probeActive {
                            HStack {
                                Button(probeBlocked ? "Release probe app" : "Block probe app") {
                                    do { try ManagedSettingsDiagnostics.setProbeBlocked(!probeBlocked); probeBlocked.toggle(); refresh() }
                                    catch { report = "Probe update failed: \(error.localizedDescription)" }
                                }
                                Button("End probe") {
                                    do { try ManagedSettingsDiagnostics.restoreProbe(); refresh() }
                                    catch { report = "Restore failed: \(error.localizedDescription)" }
                                }
                            }
                        } else if ManagedSettingsDiagnostics.probeAvailable {
                            Button("One-app probe…") { choosingProbe = true }
                        }
                    }
                }
                .sheet(isPresented: $choosingProbe) {
                    NavigationStack {
                        List {
                            Text("Isolate one app's shield for a website test. Other apps stay blocked in a temporary store. Release/Block affects only the chosen app. End probe or relaunch Slowth to restore the original stores. Saved selections, rules and timers are unchanged. Requires stopped recording, no Strict mode, pause or pending rest.")
                            ForEach(Array(GroupedApps.selection?.applicationTokens ?? []), id: \.self) { token in
                                Button {
                                    do { try ManagedSettingsDiagnostics.startProbe(token: token); probeBlocked = true; refresh() }
                                    catch { report = "Probe unavailable: \(error.localizedDescription)" }
                                    choosingProbe = false
                                } label: { Label(token) }
                            }
                        }.navigationTitle("Choose one app")
                    }
                }
                .sheet(isPresented: $choosingWeb) {
                    NavigationStack {
                        FamilyActivityPicker(selection: $webSelection)
                            .navigationTitle("Select websites only")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Apply") {
                                        do { try ManagedSettingsDiagnostics.armWebProbe(webSelection); refresh() }
                                        catch { report = "Website probe unavailable: \(error.localizedDescription)" }
                                        choosingWeb = false
                                    }
                                }
                            }
                    }
                }
                .task { refresh() }
        }
    }
    private func refresh() {
        do {
            report = try ManagedSettingsDiagnostics.export()
            probeActive = ManagedSettingsDiagnostics.probeActive
            probeBlocked = ManagedSettingsDiagnostics.probeBlocked
        }
        catch { report = "Could not export diagnostics: \(error.localizedDescription)" }
    }
}
#endif
