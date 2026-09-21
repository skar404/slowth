#if DEBUG
#if os(iOS)
import SwiftUI
import UIKit

struct DebugSessionCaptureControls: View {
    @AppStorage(SessionCaptureSettings.storageKey, store: AppGroup.defaults) private var enabled = false
    @AppStorage(SessionCaptureSettings.intervalKey, store: AppGroup.defaults) private var interval = 1.0
    @State private var showSessions = false

    var body: some View {
        Toggle("Save whole-session screenshots", isOn: $enabled)
        Picker("Screenshot interval (next broadcast)", selection: $interval) {
            Text("1 second").tag(1.0)
            Text("0.5 seconds").tag(0.5)
        }
        Text("Opt-in for your next manually started ReplayKit broadcast only. Saves all visible screens, including private information, locally as full-resolution JPEGs. No audio, video file, Photos or automatic upload. Turning this off stops collection; restart broadcasting to re-enable.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Stops at 15 minutes, 250 MiB per session, 1 GiB total or low disk space. Busy frames are dropped, not queued. Experimental: device memory/performance not qualified.")
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
    @State private var deleteRow: Row?
    @State private var renameRow: Row?
    @State private var nameDraft = ""
    @StateObject private var connection = SessionUploadConnection.shared
    @State private var showConnection = false
    @State private var sendRow: Row?
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
                    if connection.isUploading { Button("Cancel upload", role: .cancel) { uploadTask?.cancel() } }
                    if let failure = connection.initializationError { Text(failure).foregroundStyle(.red) }
                }
                if let error { Text(error).foregroundStyle(.red) }
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
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { refresh() }.disabled(busy) }
            }
            .overlay { if busy { ProgressView() } }
            .task {
                refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                    if scenePhase == .active && !connection.isUploading && !busy { refresh(preservingError: true) }
                }
            }
            .onChange(of: scenePhase) { phase in if phase == .active { refresh() } }
            .onDisappear { uploadTask?.cancel() }
            .sheet(isPresented: $showConnection) { SessionUploadConnectionView() }
            .alert("Send this snapshot to the private labeler?", isPresented: Binding(
                get: { sendRow != nil }, set: { if !$0 { sendRow = nil } })) {
                Button("Cancel", role: .cancel) { sendRow = nil }
                Button("Send private screenshots") {
                    if let row = sendRow { send(row) }
                    sendRow = nil
                }
            } message: {
                Text("All committed screenshots, raw session metadata, predictions and your session name will be sent over HTTPS to quick-draws:8443. They may contain private information. Local originals stay here. Sending does not label or merge anything. Continue?")
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
            .alert("Delete this local session?", isPresented: Binding(
                get: { deleteRow != nil }, set: { if !$0 { deleteRow = nil } })) {
                Button("Cancel", role: .cancel) { deleteRow = nil }
                Button("Delete", role: .destructive) {
                    if let row = deleteRow {
                        do { try FileManager.default.removeItem(at: row.directory) }
                        catch { self.error = error.localizedDescription }
                    }
                    deleteRow = nil
                    refresh()
                }
            } message: { Text("All screenshots and JSON in this session will be removed. Stop broadcasting first and export if needed. Deleting a live session stops its capture on the next write; blocking and ReplayKit remain unchanged.") }
        }
    }


    private func rowContent(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = row.name { Text(name).font(.headline) }
            Text(row.startedAt, style: .date) + Text(" ") + Text(row.startedAt, style: .time)
            Text(row.id.uuidString).font(.caption2).textSelection(.enabled)
            Text("\(row.status) · \(row.frames) frames · \(row.dropped) dropped").font(.caption)
            if let error = row.error { Text(error).font(.caption).foregroundStyle(.red) }
            if let uploader = connection.uploader {
                SessionUploadPanel(uploader: uploader, id: row.id, fingerprint: row.fingerprint)
                Button("Send snapshot to labeler") { sendRow = row }
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
                Button("Delete", role: .destructive) { deleteRow = row }
            }
            .buttonStyle(.borderless)
            .disabled(busy || connection.isUploading)
        }
    }

    private func refresh(preservingError: Bool = false) {
        guard !busy else { return }
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
            case .success(let rows): self.rows = rows; if !preservingError { error = nil }
            case .failure(let failure): error = failure.localizedDescription
            }
            busy = false
        }
    }

    private func send(_ row: Row) {
        guard DebugMode.isEnabled, !busy, !connection.isUploading, let uploader = connection.uploader else { return }
        error = nil
        uploadTask = Task {
            do {
                guard let token = try SessionUploadConnection.credential() else { throw SessionUploadError.permission }
                try await uploader.send(row.directory, id: row.id, token: token, permitted: { DebugMode.isEnabled })
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
