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
        Toggle("Save whole-session screenshots", isOn: $enabled)
        Picker("Screenshot interval (next broadcast)", selection: $interval) {
            Text("1 second").tag(1.0)
            Text("0.5 seconds").tag(0.5)
        }
        Picker("Storage for all sessions (next broadcast)", selection: $storageLimit) {
            ForEach(SessionCaptureSettings.StorageLimit.allCases, id: \.rawValue) { limit in
                if limit == .unlimited {
                    Text("No limit").tag(limit.rawValue)
                } else {
                    Text("\(limit.rawValue) GiB").tag(limit.rawValue)
                }
            }
        }
        Text("Opt-in for your next manually started ReplayKit broadcast only. Saves all visible screens, including private information, locally as full-resolution JPEGs. No audio, video file, Photos or automatic upload. Turning this off stops collection; restart broadcasting to re-enable.")
            .font(.caption).foregroundStyle(.secondary)
        Text("The storage limit includes all saved sessions and applies to the next broadcast. Capture stops when the selected limit is reached; existing sessions are kept. No limit removes the storage cap. Capture still stops after 15 minutes or when disk space is low. Busy frames are dropped, not queued. Experimental: device memory/performance not qualified.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Local screenshot sessions / Share ZIP") { showSessions = true }
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
                    Text("ZIP contains original JPEGs, session.json and your session name, if set. Predictions are not human labels. Review private screens and the name before sharing. No data is sent until you choose a Share destination.")
                    Text("Stop broadcasting and refresh for the complete session. Share also works after a crash: active/paused entries export a consistent snapshot of committed frames, not a claim of completion.")
                }.font(.caption)
                Section {
                    Button("Labeler connection") { showConnection = true }.disabled(connection.isUploading)
                    Text("Manual private upload keeps all local originals. No labels, merge or holdout assignment. Status covers bytes at the last refresh; stop broadcasting before sending the complete recording.").font(.caption)
                    if let uploader = connection.uploader {
                        Button("Upload all screenshots") {
                            if (try? SessionUploadServer.url(from: serverAddress)) == nil {
                                showConnection = true
                            } else {
                                sendingAll = true
                                sendRows = rows
                            }
                        }
                        .disabled(busy || connection.isUploading || uploadTask != nil || !DebugMode.isEnabled || rows.isEmpty)
                        Text("Uploads every session in order, skipping unchanged snapshots already accepted by the labeler.")
                            .font(.caption).foregroundStyle(.secondary)
                        SessionUploadProgress(uploader: uploader)
                    }
                    if connection.isUploading { Button("Cancel upload", role: .cancel) { uploadTask?.cancel() } }
                    if let failure = connection.initializationError { Text(failure).foregroundStyle(.red) }
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
                    .disabled(busy || connection.isUploading)
                }
                if rows.isEmpty { Text("No local screenshot sessions") }
                ForEach(rows) { row in
                    if let uploader = connection.uploader {
                        rowContent(row)
                            .modifier(SessionUploadRowStyle(uploader: uploader, id: row.id, fingerprint: row.fingerprint))
                    } else {
                        rowContent(row)
                    }
                }
            }
            .navigationTitle("Screenshot sessions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(selecting ? "Cancel selection" : "Select") {
                        selecting.toggle()
                        selectedIDs.removeAll()
                    }
                    .disabled(busy || connection.isUploading || rows.isEmpty)
                    Button("Refresh") { refresh() }.disabled(busy || connection.isUploading)
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
        VStack(alignment: .leading, spacing: 8) {
            if let name = row.name { Text(name).font(.headline) }
            Text(row.startedAt, style: .date) + Text(" ") + Text(row.startedAt, style: .time)
            Text(row.id.uuidString).font(.caption2).textSelection(.enabled)
            Text("\(row.status) · \(row.frames) frames · \(row.dropped) dropped").font(.caption)
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
            .disabled(busy || connection.isUploading)
        } else {
            sessionActions(row)
        }
    }

    private func sessionActions(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sessionDetails(row)
            if let uploader = connection.uploader {
                SessionUploadPanel(uploader: uploader, id: row.id, fingerprint: row.fingerprint)
                Button("Send snapshot to labeler") {
                    if (try? SessionUploadServer.url(from: serverAddress)) == nil {
                        showConnection = true
                    } else {
                        sendingAll = false
                        sendRows = [row]
                    }
                }
                    .buttonStyle(.borderless)
                    .disabled(busy || connection.isUploading || !DebugMode.isEnabled || row.fingerprint == nil)
            }
            HStack {
                Button("Rename") {
                    nameDraft = row.name ?? ""
                    renameRow = row
                }
                Button("Share snapshot ZIP") { export(row) }
                Spacer()
                Button("Delete", role: .destructive) { pendingDeletion = [row] }
            }
            .buttonStyle(.borderless)
            .disabled(busy || connection.isUploading)
        }
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
        guard !busy, !connection.isUploading, pendingDeletion.isEmpty else { return }
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
                                error: manifest.error, fingerprint: try? SessionUploadIdentity.fingerprint(directory))
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
#endif
#endif
