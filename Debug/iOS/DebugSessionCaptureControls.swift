#if DEBUG
#if os(iOS)
import SwiftUI
import UIKit

struct DebugSessionCaptureControls: View {
    @AppStorage(SessionCaptureSettings.storageKey, store: AppGroup.defaults) private var enabled = false
    @AppStorage(SessionCaptureSettings.intervalKey, store: AppGroup.defaults) private var interval = 1.0
    @AppStorage(SessionCaptureSettings.storageLimitKey, store: AppGroup.defaults) private var storageLimit = 0
    @State private var showSessions = false

    var body: some View {
        Toggle("Save session screenshots", isOn: $enabled)
        Picker("Capture interval", selection: $interval) {
            Text("1 second").tag(1.0)
            Text("0.5 seconds").tag(0.5)
        }
        Picker("Storage limit", selection: $storageLimit) {
            ForEach(SessionCaptureSettings.StorageLimit.allCases, id: \.rawValue) { limit in
                if limit == .unlimited {
                    Text("No limit").tag(limit.rawValue)
                } else {
                    Text("\(limit.rawValue) GiB").tag(limit.rawValue)
                }
            }
        }
        Button { showSessions = true } label: {
            Label("Saved sessions", systemImage: "photo.stack")
        }
        .sheet(isPresented: $showSessions) { DebugSessionList() }
    }
}

private struct DebugSessionList: View {
    struct Row: Identifiable {
        let id: UUID
        let directory: URL
        let name: String?
        let startedAt: Date
        let status: String
        let frames: Int
        let dropped: Int
        let error: String?
        let fingerprint: String?
        let legacyLabelerCompatible: Bool

    }
    struct Share: Identifiable {
        let id = UUID()
        let url: URL
    }
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var busy = false
    @State private var error: String?
    @State private var share: Share?
    @State private var exportedURL: URL?
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingDeletion: [Row] = []
    @State private var renameRow: Row?
    @State private var nameDraft = ""
    @StateObject private var connection = SessionUploadConnection.shared
    @ObservedObject private var transfers = DebugTransferStore.shared
    @State private var showTransfers = false
    @AppStorage(SessionUploadServer.storageKey) private var serverAddress = ""
    @State private var showConnection = false
    @State private var sendRows: [Row] = []
    @State private var sendingAll = false
    @State private var uploadTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showTransfers = true } label: {
                        DebugToolLabel("Transfers", detail: "Choose a connection or send queued sessions", icon: "arrow.up.arrow.down", color: .teal, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if selecting {
                    Section {
                        Button(selectedIDs.count == rows.count ? "Deselect all" : "Select all") {
                            selectedIDs = selectedIDs.count == rows.count ? [] : Set(rows.map(\.id))
                        }
                        Button("Delete selected (\(selectedIDs.count))", role: .destructive) {
                            pendingDeletion = rows.filter { selectedIDs.contains($0.id) }
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                    .disabled(busy || connection.isUploading || transfers.preparing)
                }
                Section("Saved sessions") {
                    if rows.isEmpty && !busy {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No screenshots yet").font(.headline)
                            Text("Enable screenshot capture, then start a screen recording.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(rows) { row in
                        if let uploader = connection.uploader {
                            rowContent(row)
                                .modifier(SessionUploadRowStyle(uploader: uploader, id: row.id, fingerprint: row.fingerprint))
                        } else {
                            rowContent(row)
                        }
                    }
                }
                Section {
                    DisclosureGroup("About sharing") {
                        Text("ZIPs include original images, metadata, predictions and the session name. Review private screens before sharing; predictions are not human labels.")
                        Text("Stop recording for a complete session. While recording, exports contain only frames already saved. Capture can drop frames if encoding or storage cannot keep up.")
                    }.font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Legacy labeler · JPEG sessions") {
                        Button("Labeler connection") { showConnection = true }.disabled(connection.isUploading)
                        Text("Manual private upload keeps all local originals. No labels, merge or holdout assignment. Status covers bytes at the last refresh; stop broadcasting before sending the complete recording.").font(.caption)
                        if let uploader = connection.uploader {
                            Button("Upload legacy JPEG sessions to labeler") {
                                if (try? SessionUploadServer.url(from: serverAddress)) == nil {
                                    showConnection = true
                                } else {
                                    sendingAll = true
                                    sendRows = rows.filter(\.legacyLabelerCompatible)
                                }
                            }
                            .disabled(busy || connection.isUploading || uploadTask != nil || !DebugMode.isEnabled || !rows.contains(where: \.legacyLabelerCompatible))
                            Text("Legacy labeler upload is available for older JPEG sessions. Use Transfers for new PNG sessions.")
                                .font(.caption).foregroundStyle(.secondary)
                            SessionUploadProgress(uploader: uploader)
                        }
                        if connection.isUploading { Button("Cancel upload", role: .cancel) { uploadTask?.cancel() } }
                        if let failure = connection.initializationError { Text(failure).foregroundStyle(.red) }
                    }
                }
            }
            .debugFormStyle()
            .navigationTitle("Saved sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(selecting ? "Cancel selection" : "Select") {
                        selecting.toggle()
                        selectedIDs.removeAll()
                    }
                    .disabled(busy || connection.isUploading || rows.isEmpty)
                    Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(busy || connection.isUploading || transfers.preparing)
                }
            }
            .overlay { if busy { ProgressView() } }
            .task {
                refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                    if scenePhase == .active && !connection.isUploading && !busy && pendingDeletion.isEmpty {
                        refresh(preservingError: true)
                    }
                }
            }
            .onChange(of: scenePhase) { phase in if phase == .active { refresh() } }
            .onDisappear { uploadTask?.cancel() }
            .sheet(isPresented: $showConnection) { SessionUploadConnectionView() }
            .sheet(isPresented: $showTransfers) { DebugTransfersView() }
            .alert(sendingAll ? "Upload all screenshots to the private labeler?" : "Send this snapshot to the private labeler?", isPresented: Binding(
                get: { !sendRows.isEmpty }, set: { if !$0 { sendRows = [] } })) {
                Button("Cancel", role: .cancel) { sendRows = [] }
                Button("Send private screenshots") {
                    send(sendRows, batch: sendingAll)
                    sendRows = []
                }
            } message: {
                Text("All committed screenshots, raw session metadata, predictions and your session name will be sent to \(serverAddress). They may contain private information. Local originals stay here. Sending does not label or merge anything. Continue?")
            }
            .sheet(item: $share, onDismiss: cleanupExport) { item in
                SessionShareSheet(url: item.url)
            }
            .alert("Rename session", isPresented: Binding(
                get: { renameRow != nil }, set: { if !$0 { renameRow = nil } })) {
                TextField("Session name", text: $nameDraft)
                Button("Cancel", role: .cancel) { renameRow = nil; nameDraft = "" }
                Button("Save") {
                    if let row = renameRow { rename(row, to: nameDraft) }
                    renameRow = nil
                }
                .disabled((try? SessionCaptureName.normalized(nameDraft)) == nil)
            } message: {
                Text("Use 1–120 characters, without line breaks. Spaces at the ends are trimmed. The name is included in shared ZIPs; the recording ID and screenshots stay unchanged.")
            }
            .alert("Delete \(pendingDeletion.count) local sessions?", isPresented: Binding(
                get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
                presenting: pendingDeletion) { targets in
                Button("Cancel", role: .cancel) { pendingDeletion = [] }
                Button("Delete \(targets.count)", role: .destructive) {
                    delete(targets)
                    pendingDeletion = []
                }
            } message: { _ in Text("All screenshots and JSON in the selected sessions will be removed from this device. Stop broadcasting first and export if needed. Deleting a live session stops its capture on the next write; blocking and ReplayKit remain unchanged.") }
        }
    }


    private func sessionDetails(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let name = row.name { Text(name) }
                else { Text(row.startedAt.formatted(date: .abbreviated, time: .shortened)) }
            }.font(.headline)
            if row.name != nil {
                Text(row.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("\(row.frames) frames · \(row.status.capitalized)")
                .font(.subheadline).foregroundStyle(.secondary)
            if row.dropped > 0 {
                Label("\(row.dropped) dropped frames", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(SlowthAppearance.pause)
            }
            if let error = row.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private func rowContent(_ row: Row) -> some View {
        if selecting {
            Button {
                if !selectedIDs.insert(row.id).inserted { selectedIDs.remove(row.id) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selectedIDs.contains(row.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Color.accentColor)
                    sessionDetails(row)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedIDs.contains(row.id) ? .isSelected : [])
            .disabled(busy || connection.isUploading || transfers.preparing)
        } else {
            sessionActions(row)
        }
    }

    private func sessionActions(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                sessionDetails(row)
                Spacer(minLength: 8)
                Menu {
                    Button("Rename") {
                        nameDraft = row.name ?? ""
                        renameRow = row
                    }
                    Button("Share snapshot ZIP") { export(row) }
                    Button("Delete", role: .destructive) { pendingDeletion = [row] }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Actions for \(row.name ?? row.startedAt.formatted())")
                .disabled(busy || connection.isUploading || transfers.preparing)
            }
            DisclosureGroup("Transfer and details") {
                VStack(alignment: .leading, spacing: 12) {
                    DebugTransferRecordingButton { .screenshots(row.directory, row.id) }
                    if row.legacyLabelerCompatible, let uploader = connection.uploader {
                        SessionUploadPanel(uploader: uploader, id: row.id, fingerprint: row.fingerprint)
                        Button("Send snapshot to labeler") {
                            if (try? SessionUploadServer.url(from: serverAddress)) == nil {
                                showConnection = true
                            } else {
                                sendingAll = false
                                sendRows = [row]
                            }
                        }
                        .disabled(busy || connection.isUploading || !DebugMode.isEnabled || row.fingerprint == nil)
                    }
                    Text(row.id.uuidString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(.vertical, 6)
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
    }

    private func delete(_ targets: [Row]) {
        guard !busy, !connection.isUploading, !targets.isEmpty else { return }
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                SessionCaptureDeletion.remove(targets.map(\.directory))
            }.value
            let deletedIDs = Set(targets.filter { result.deleted.contains($0.directory) }.map(\.id))
            rows.removeAll { deletedIDs.contains($0.id) }
            selectedIDs.subtract(deletedIDs)
            if rows.isEmpty { selecting = false }
            if !result.failures.isEmpty {
                error = "Deleted \(result.deleted.count) of \(targets.count) sessions. " + result.failures.map {
                    "\($0.directory.lastPathComponent): \($0.message)"
                }.joined(separator: "\n")
            }
            busy = false
            refresh(preservingError: true)
        }
    }

    private func refresh(preservingError: Bool = false) {
        guard !busy, !connection.isUploading, !transfers.preparing, pendingDeletion.isEmpty else { return }
        busy = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<[Row], Error> in
                Result {
                    guard let root = SessionCaptureSettings.rootDirectory else { throw CocoaError(.fileNoSuchFile) }
                    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
                    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        .compactMap { directory -> Row? in
                            guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                                  let manifest = try? JSONDecoder().decode(SessionCapture.Manifest.self, from: data) else { return nil }
                            return Row(id: manifest.sessionID, directory: directory,
                                name: try? SessionCaptureName.load(from: directory), startedAt: manifest.startedAt,
                                status: manifest.status, frames: manifest.frames.count, dropped: manifest.droppedFrames,
                                error: manifest.error, fingerprint: try? SessionUploadIdentity.fingerprint(directory),
                                legacyLabelerCompatible: manifest.formatVersion == 1 && manifest.frames.allSatisfy { $0.filename.hasSuffix(".jpg") })
                        }.sorted { $0.startedAt > $1.startedAt }
                }
            }.value
            switch result {
            case .success(let rows):
                self.rows = rows
                selectedIDs.formIntersection(Set(rows.map(\.id)))
                if rows.isEmpty { selecting = false }
                if !preservingError { error = nil }
            case .failure(let failure): error = failure.localizedDescription
            }
            busy = false
        }
    }

    private func send(_ targets: [Row], batch: Bool) {
        guard DebugMode.isEnabled, !busy, !connection.isUploading, uploadTask == nil,
              !targets.isEmpty, let uploader = connection.uploader else { return }
        error = nil
        uploadTask = Task {
            do {
                let serverURL = try SessionUploadServer.url(from: serverAddress)
                guard let token = try SessionUploadConnection.credential(for: serverURL) else { throw SessionUploadError.permission }
                if batch {
                    try await uploader.sendAll(targets.map { SessionUploader.Item(directory: $0.directory, id: $0.id) },
                                               serverURL: serverURL, token: token, permitted: { DebugMode.isEnabled })
                } else if let row = targets.first {
                    try await uploader.send(row.directory, id: row.id, serverURL: serverURL, token: token, permitted: { DebugMode.isEnabled })
                }
            } catch is CancellationError {
                error = "Upload cancelled. Server acceptance may be unknown; retry manually. Local originals remain."
            } catch let failure as SessionUploadError { error = failure.localizedDescription }
            catch { self.error = "Upload failed or was interrupted. Check Tailscale, connection settings and local storage; retry manually. Local originals remain." }
            uploadTask = nil
            // Do not clear the error banner while refreshing the checked fingerprint.
            refresh(preservingError: true)
        }
    }

    private func rename(_ row: Row, to name: String) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try SessionCaptureName.rename(in: row.directory, to: name) }
            }.value
            busy = false
            switch result {
            case .success: refresh()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func export(_ row: Row) {
        guard !busy else { return }
        cleanupExport()
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                Result {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("slowth-\(row.id.uuidString)-\(UUID().uuidString).zip")
                    return try SessionCaptureArchive.export(row.directory, to: destination)
                }
            }.value
            switch result {
            case .success(let url): exportedURL = url; share = Share(url: url)
            case .failure(let failure): error = failure.localizedDescription
            }
            busy = false
        }
    }

    private func cleanupExport() {
        if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
        exportedURL = nil
    }
}

private struct SessionShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview("Session capture controls") {
    Form { DebugSessionCaptureControls() }.allowsHitTesting(false)
}

#endif
#endif
