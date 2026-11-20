#if DEBUG && os(iOS)
import Foundation
import Security
import SwiftUI

@MainActor
final class DebugTransferStore: ObservableObject {
    static let shared = DebugTransferStore()
    enum Status: String, Codable { case pending, sending, paused, error, sent }
    struct Job: Codable, Identifiable {
        let id: UUID
        let profile: DebugTransferProfile
        let snapshot: DebugTransferSnapshot
        let createdAt: Date
        var status: Status = .pending
        var completed = 0
        var error: String?
    }
    private struct State: Codable {
        var profiles: [DebugTransferProfile] = []
        var selectedID: UUID?
        var jobs: [Job] = []
    }
    @Published private var state = State()
    @Published private(set) var preparing = false
    @Published private(set) var runningID: UUID?
    @Published private(set) var fraction = 0.0
    @Published var message: String?
    private var ready = true
    private var task: Task<Void, Never>?
    var profiles: [DebugTransferProfile] { state.profiles }
    var jobs: [Job] { state.jobs }
    var selected: DebugTransferProfile? { profiles.first { $0.id == state.selectedID } }
    var busy: Bool { preparing || task != nil }
    private let root: URL
    private var index: URL { root.appendingPathComponent("index.json") }
    private var snapshots: URL { root.appendingPathComponent("snapshots", isDirectory: true) }

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DebugTransfers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var location = root; var properties = URLResourceValues(); properties.isExcludedFromBackup = true
            try location.setResourceValues(properties)
            if FileManager.default.fileExists(atPath: index.path) {
                var saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: index))
                for index in saved.jobs.indices where saved.jobs[index].status == .sending { saved.jobs[index].status = .paused }
                for profile in saved.profiles { _ = try profile.validated() }
                state = saved
            }
        } catch { ready = false; message = "Could not read transfer history. Existing files were preserved. Restart Slowth and try again." }
    }
    private func commit(_ next: State) throws {
        guard ready else { throw DebugTransferError.invalidSnapshot }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try encoder.encode(next).write(to: index, options: .atomic)
        state = next
    }
    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        var next = state; next.selectedID = id
        do { try commit(next) } catch { message = "Could not save the selected connection." }
    }
    func save(profile: DebugTransferProfile, credentials: DebugTransferSecret?) throws {
        guard !busy else { throw DebugTransferError.busy }
        let profile = try profile.validated()
        // New profiles are immutable destinations; queued work keeps its original destination.
        guard !profiles.contains(where: { $0.id == profile.id }) else { throw DebugTransferError.invalidProfile }
        if profile.transport == .s3 {
            guard let credentials else { throw DebugTransferError.missingCredentials }
            try credentials.validate()
            try Self.writeSecret(credentials, id: profile.id)
        }
        var next = state; next.profiles.append(profile); next.selectedID = profile.id
        do { try commit(next); message = "Connection saved. No recordings were sent." }
        catch { try? Self.deleteSecret(id: profile.id); throw error }
    }
    func forget(_ profile: DebugTransferProfile) throws {
        guard !busy, !jobs.contains(where: { $0.profile.id == profile.id && $0.status != .sent }) else { throw DebugTransferError.busy }
        // If Keychain is unavailable, keep the visible profile so removal can be retried.
        try Self.deleteSecret(id: profile.id)
        var next = state; next.profiles.removeAll { $0.id == profile.id }
        if next.selectedID == profile.id { next.selectedID = next.profiles.first?.id }
        try commit(next)
    }
    func enqueue(_ source: DebugTransferSnapshot.Source, profileID: UUID) async throws {
        guard !busy else { throw DebugTransferError.busy }
        guard let profile = profiles.first(where: { $0.id == profileID }) else { throw DebugTransferError.invalidProfile }
        preparing = true
        defer { preparing = false }
        let root = snapshots
        let operation = Task.detached(priority: .utility) { try DebugTransferSnapshot.prepare(source, root: root) }
        let snapshot = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
        try Task.checkCancellation()
        if jobs.contains(where: { $0.profile.destinationID == profile.destinationID && $0.snapshot.id == snapshot.id && $0.status == .sent }) {
            message = "This exact snapshot was already sent to this destination."; return
        }
        var next = state
        if let i = next.jobs.firstIndex(where: { $0.profile.id == profile.id && $0.snapshot.id == snapshot.id }) {
            next.jobs[i].status = .pending; next.jobs[i].error = nil
        } else { next.jobs.append(.init(id: UUID(), profile: profile, snapshot: snapshot, createdAt: Date())) }
        try commit(next); message = "Snapshot queued. Open Transfers and tap Send pending."
    }
    func retry(_ id: UUID) {
        guard !busy, let i = state.jobs.firstIndex(where: { $0.id == id && $0.status != .sent }) else { return }
        var next = state; next.jobs[i].status = .pending; next.jobs[i].error = nil
        do { try commit(next); start() } catch { message = "Could not update the queue." }
    }
    func remove(_ id: UUID) {
        guard !busy, let job = jobs.first(where: { $0.id == id }) else { return }
        var next = state; next.jobs.removeAll { $0.id == id }
        do {
            try commit(next)
            if !jobs.contains(where: { $0.snapshot.id == job.snapshot.id }) {
                try? FileManager.default.removeItem(at: snapshots.appendingPathComponent(job.snapshot.id))
            }
        } catch { message = "Could not remove the queued snapshot. Original recordings remain." }
    }
    func pause() { task?.cancel() }
    func start() {
        guard !busy, ready else { return }
        task = Task {
            defer { self.task = nil; runningID = nil; fraction = 0 }
            let pending = jobs.filter { $0.status == .pending || $0.status == .paused }
            for job in pending {
                if Task.isCancelled { break }
                runningID = job.id; fraction = 0
                do {
                    try update(job.id, status: .sending, error: nil)
                    let secret = job.profile.transport == .s3 ? try Self.readSecret(id: job.profile.id) : nil
                    let network = DebugTransferNetwork()
                    try await DebugTransferTransport.send(snapshot: job.snapshot,
                        directory: snapshots.appendingPathComponent(job.snapshot.id), profile: job.profile, secret: secret,
                        execute: { request, file, progress in try await network.execute(request, file: file, progress: progress) }) { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self, self.runningID == job.id,
                                      let i = self.state.jobs.firstIndex(where: { $0.id == job.id && $0.status == .sending }) else { return }
                                self.fraction = progress.fraction
                                if self.state.jobs[i].completed != progress.completed {
                                    var next = self.state; next.jobs[i].completed = progress.completed
                                    do { try self.commit(next) } catch { self.message = "Could not save transfer progress." }
                                }
                            }
                        }
                    try Task.checkCancellation()
                    try update(job.id, status: .sent, error: nil)
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError
                    let description = cancelled ? "Paused. Retry checks the files already received." :
                        (error as? DebugTransferError)?.localizedDescription ?? "Transfer interrupted. Check the connection, unlock the phone and retry."
                    do { try update(job.id, status: cancelled ? .paused : .error, error: description) }
                    catch { message = "Could not save the result. Transfer acceptance is unknown." }
                    if cancelled { break }
                }
            }
        }
    }
    private func update(_ id: UUID, status: Status, error: String?) throws {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }) else { return }
        var next = state; next.jobs[i].status = status; next.jobs[i].error = error
        if status == .sent { next.jobs[i].completed = next.jobs[i].snapshot.inventory.files.count + 1 }
        try commit(next)
    }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "slowth.debug-transfer.s3.v1", kSecAttrAccount as String: id.uuidString]
    }
    private static func writeSecret(_ secret: DebugTransferSecret, id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(secret),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw DebugTransferError.missingCredentials }
    }
    private static func readSecret(id: UUID) throws -> DebugTransferSecret {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let value = try? JSONDecoder().decode(DebugTransferSecret.self, from: data) else { throw DebugTransferError.missingCredentials }
        return value
    }
    private static func deleteSecret(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DebugTransferError.missingCredentials }
    }
}
#endif
