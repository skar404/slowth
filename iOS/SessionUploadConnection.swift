#if DEBUG
#if os(iOS)
import SwiftUI
import Security
import Combine

@MainActor final class SessionUploadConnection: ObservableObject {
    static let shared = SessionUploadConnection()
    let uploader: SessionUploader?
    let initializationError: String?
    @Published var isUploading = false
    private var observation: AnyCancellable?
    private static func query(for serverURL: URL) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.malin.unscroll.ios.private-session-upload",
        kSecAttrAccount as String: serverURL.absoluteString
    ] }
    private init() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            let uploader = try SessionUploader(indexURL: root.appendingPathComponent("SessionUploads/index.json"))
            self.uploader = uploader
            initializationError = nil
            observation = uploader.$isUploading.sink { [weak self] in self?.isUploading = $0 }
        } catch {
            uploader = nil
            initializationError = "Upload index unavailable. No upload will be attempted. Local sessions remain safe."
        }
    }
    static func credential(for serverURL: URL) throws -> String? {
        var query = query(for: serverURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SessionUploadError.permission
        }
        return value
    }
    static func save(_ value: String, for serverURL: URL) throws {
        guard DebugMode.isEnabled,
              value.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression) != nil else {
            throw SessionUploadError.permission
        }
        let query = query(for: serverURL)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SessionUploadError.permission }
        guard try credential(for: serverURL) == value else { throw SessionUploadError.permission }
    }
    static func forget(for serverURL: URL) throws {
        let status = SecItemDelete(query(for: serverURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionUploadError.permission }
        guard try credential(for: serverURL) == nil else { throw SessionUploadError.permission }
    }
}

struct SessionUploadConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SessionUploadServer.storageKey) private var serverAddress = ""
    @State private var draft = ""
    @State private var message: String?
    private var serverURL: URL? { try? SessionUploadServer.url(from: serverAddress) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Private labeler") {
                    TextField("Labeler URL (https://host:port)", text: $serverAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("The address is saved automatically on this device.").font(.caption)
                    if let serverURL {
                        Link("Open labeler in browser", destination: serverURL)
                    } else if !serverAddress.isEmpty {
                        Text("Enter a valid HTTPS address without a username, password, query or fragment.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("Enable Tailscale. In the browser open ‘Подключить Slowth iOS’, request the credential and copy it here yourself. Never put it in chat. Saving a credential does not send screenshots.")
                    SecureField("Private upload credential", text: $draft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save in this device’s Keychain") {
                        guard let serverURL else { return }
                        do { try SessionUploadConnection.save(draft.trimmingCharacters(in: .whitespacesAndNewlines), for: serverURL); draft = ""; message = "Saved. Choose Upload all screenshots or send an individual session." }
                        catch { message = "Could not save credential. Check the value and unlock Debug." }
                    }.disabled(!DebugMode.isEnabled || draft.isEmpty || serverURL == nil)
                    Button("Forget saved credential", role: .destructive) {
                        guard let serverURL else { return }
                        do { try SessionUploadConnection.forget(for: serverURL); draft = ""; message = "Credential removed from this device." }
                        catch { message = "Could not remove credential." }
                    }.disabled(serverURL == nil)
                    if let message { Text(message).font(.caption) }
                    Text("The key is device-only, available while unlocked, not synced or placed in App Group defaults. To revoke all connected devices, rotate the server’s private token file and restart the service. Clear your clipboard after pairing.").font(.caption)
                }
            }
            .navigationTitle("Labeler connection")
            .toolbar { Button("Done") { draft = ""; dismiss() } }
            .onDisappear { draft = "" }
            .onChange(of: serverAddress) { _ in draft = ""; message = nil }
            .onChange(of: scenePhase) { phase in if phase != .active { draft = "" } }
        }
    }
}

struct SessionUploadProgress: View {
    @ObservedObject var uploader: SessionUploader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let batch = uploader.batchProgress {
                let fraction = uploader.isUploading ? min(uploader.transferProgress ?? 0, 0.99) : 0
                ProgressView(value: Double(batch.completed) + fraction, total: Double(max(batch.total, 1)))
                Text("Processed \(batch.completed) of \(batch.total) sessions")
                Text("Uploaded: \(batch.sent) · Already sent: \(batch.skipped) · Failed: \(batch.failures.count)")
                    .foregroundStyle(.secondary)
                if !batch.failures.isEmpty {
                    DisclosureGroup("Upload errors") {
                        Text(batch.failures.joined(separator: "\n")).foregroundStyle(.red)
                    }
                }
            }
            if uploader.isUploading {
                if let fraction = uploader.transferProgress {
                    ProgressView(value: fraction) {
                        Text(fraction >= 1 ? "Waiting for server acceptance…" : "Current session: \(Int(fraction * 100))%")
                    }
                } else {
                    ProgressView("Preparing screenshots…")
                }
            }
        }
        .font(.caption)
    }
}

// Observe receipt revisions directly so the whole row updates with its status.
struct SessionUploadRowStyle: ViewModifier {
    @ObservedObject var uploader: SessionUploader
    let id: UUID
    let fingerprint: String?

    func body(content: Content) -> some View {
        let state = fingerprint.map { uploader.index.status(id, fingerprint: $0) } ?? .notSent
        let sent = uploader.uploadingID != id && state.isSentPresentation
        content
            .foregroundStyle(sent ? Color(uiColor: .label) : Color.primary)
            .listRowBackground(sent ? Color(uiColor: .systemGray5) : Color(uiColor: .secondarySystemGroupedBackground))
    }
}

struct SessionUploadPanel: View {
    @ObservedObject var uploader: SessionUploader
    let id: UUID
    let fingerprint: String?
    var body: some View {
        let state = fingerprint.map { uploader.index.status(id, fingerprint: $0) } ?? .notSent
        let sending = uploader.uploadingID == id
        VStack(alignment: .leading) {
            Text(sending ? "Uploading snapshot…" : title(state)).font(.caption)
            if !sending, state == .notSent, uploader.index.entries[id.uuidString] != nil {
                Text("Local snapshot changed since the last attempt. Earlier acceptance does not cover these bytes. A changed UUID snapshot may be rejected with 409.").font(.caption2)
            }
        }
    }
    private func title(_ state: SessionUploadState) -> String {
        switch state {
        case .notSent: return "Not sent (current checked snapshot)"
        case .uploading: return "Uploading snapshot…"
        case .accepted: return "Sent — accepted by labeler (exact checked snapshot)"
        case .error: return "Error / interrupted — acceptance unknown; retry manually"
        }
    }
}
#endif
#endif
