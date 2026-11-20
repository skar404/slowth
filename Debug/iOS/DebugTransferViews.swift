#if DEBUG && os(iOS)
import SwiftUI

struct DebugTransfersView: View {
    @StateObject private var store = DebugTransferStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var draft: DebugTransferLink?
    @State private var pastedLink = ""
    @State private var forget: DebugTransferProfile?
    @State private var remove: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connections") {
                    if store.profiles.isEmpty {
                        Label("Add a destination for your recordings.", systemImage: "network")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.profiles) { profile in
                        HStack {
                            Button { store.select(profile.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(profile.name, systemImage: store.selected?.id == profile.id ? "checkmark.circle.fill" : "circle")
                                    Text(profile.destination).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.borderless)
                            Spacer()
                            Button(role: .destructive) { forget = profile } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("Forget connection")
                        }.disabled(store.busy)
                    }
                    Button {
                        draft = .init(version: 1, profile: .init(name: "", transport: .http, endpoint: ""), credentials: nil)
                    } label: { Label("Add connection", systemImage: "plus.circle") }
                    .disabled(store.busy)
                    DisclosureGroup("Import connection link") {
                        SecureField("Paste connection deeplink", text: $pastedLink)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Import link") {
                            defer { pastedLink = "" }
                            do {
                                guard let url = URL(string: pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw DebugTransferError.invalidLink }
                                draft = try DebugTransferLink.parse(url)
                            } catch { store.message = "Invalid connection link. No settings were changed." }
                        }.disabled(pastedLink.isEmpty || store.busy)
                    }
                }
                Section {
                    if store.busy {
                        if store.preparing { ProgressView("Preparing snapshot…") }
                        else {
                            ProgressView("Sending recordings…", value: store.fraction)
                            Button { store.pause() } label: { Label("Pause transfer", systemImage: "pause.circle") }
                        }
                    } else {
                        Button { store.start() } label: { Label("Send pending", systemImage: "arrow.up.circle.fill") }
                            .disabled(!store.jobs.contains { $0.status == .pending || $0.status == .paused })
                    }
                    ForEach(store.jobs.reversed()) { job in
                        transferRow(job)
                    }
                    if store.jobs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Queue is empty").font(.headline)
                            Text("Add a snapshot from Saved sessions or Scroll motion.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                } header: { Text("Upload queue") } footer: {
                    Text("Keep Slowth open while sending. Each snapshot keeps the destination selected when it was queued.")
                }
                if let message = store.message { Section { Text(message).font(.footnote) } }
            }
            .debugFormStyle()
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $draft) { DebugTransferConnectionView(link: $0) }
            .onChange(of: phase) { if $0 == .background { pastedLink = ""; store.pause() } }
            .onDisappear { pastedLink = "" }
            .alert("Forget connection?", isPresented: Binding(get: { forget != nil }, set: { if !$0 { forget = nil } })) {
                Button("Cancel", role: .cancel) { forget = nil }
                Button("Forget", role: .destructive) {
                    if let forget {
                        do { try store.forget(forget) }
                        catch { store.message = "Remove unfinished queued copies for this connection first, then try again." }
                    }
                    forget = nil
                }
            } message: { Text("Removes this profile and its device-only credentials. Remote recordings stay in place.") }
            .alert("Remove queued copy?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } })) {
                Button("Cancel", role: .cancel) { remove = nil }
                Button("Remove", role: .destructive) { if let remove { store.remove(remove) }; remove = nil }
            } message: { Text("Original recordings and remote files stay in place. This removes only the transfer history entry and its unused local staging copy.") }
        }
    }
    private func transferRow(_ job: DebugTransferStore.Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: job.snapshot.inventory.kind == "motion" ? "waveform.path" : "photo.stack")
                    .foregroundStyle(.secondary).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.snapshot.inventory.kind == "motion" ? "Motion recording" : "Screenshots").font(.headline)
                    Text("To \(job.profile.name) · \(ByteCountFormatter.string(fromByteCount: job.snapshot.bytes, countStyle: .file))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Label(status(job), systemImage: statusIcon(job))
                .font(.caption).foregroundStyle(job.status == .error ? Color.red : Color.secondary)
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.profile.destination)
                    Text(job.snapshot.inventory.sessionID.uuidString).textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }.font(.subheadline)
            HStack {
                if job.status == .error || job.status == .paused {
                    Button { store.retry(job.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                }
                Spacer()
                Button("Remove queued copy", role: .destructive) { remove = job.id }
            }.font(.subheadline).buttonStyle(.borderless).disabled(store.busy)
        }.padding(.vertical, 6)
    }

    private func statusIcon(_ job: DebugTransferStore.Job) -> String {
        switch job.status {
        case .pending: return "clock"
        case .sending: return "arrow.up.circle"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        case .sent: return "checkmark.circle"
        }
    }

    private func status(_ job: DebugTransferStore.Job) -> String {
        switch job.status {
        case .pending: return "Queued"
        case .sending: return "Verified \(job.completed) of \(job.snapshot.inventory.files.count + 1) files"
        case .paused: return "Paused — resume when Slowth is open"
        case .error: return "Not confirmed — retry available"
        case .sent: return job.profile.transport == .s3 ? "Sent · PUT + HEAD size/hash metadata verified" : "Sent · receiver verified file hashes"
        }
    }
}

struct DebugTransferConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var store = DebugTransferStore.shared
    @State private var profile: DebugTransferProfile
    @State private var accessKey: String
    @State private var secretKey: String
    @State private var token: String
    @State private var message: String?
    init(link: DebugTransferLink) {
        _profile = State(initialValue: link.profile)
        _accessKey = State(initialValue: link.credentials?.accessKeyID ?? "")
        _secretKey = State(initialValue: link.credentials?.secretAccessKey ?? "")
        _token = State(initialValue: link.credentials?.sessionToken ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                    Picker("Transport", selection: $profile.transport) {
                        Text("Local HTTP · no token").tag(DebugTransferProfile.Transport.http)
                        Text("S3").tag(DebugTransferProfile.Transport.s3)
                    }
                    TextField("Endpoint URL", text: $profile.endpoint).keyboardType(.URL)
                    if profile.transport == .http {
                        Text("Use the local receiver address, for example http://192.168.1.10:8765. No token is used.").font(.caption)
                    } else {
                        TextField("Region", text: $profile.region)
                        TextField("Bucket", text: $profile.bucket)
                        TextField("Folder prefix (optional)", text: $profile.prefix)
                        SecureField("Access key ID", text: $accessKey)
                        SecureField("Secret access key", text: $secretKey)
                        SecureField("Session token (optional)", text: $token)
                        Text("S3 credentials stay in this device’s Keychain. HTTPS, path-style buckets and Signature V4 are used.").font(.caption)
                    }
                    Button("Save connection") {
                        do {
                            let credentials = profile.transport == .s3 ? DebugTransferSecret(accessKeyID: accessKey, secretAccessKey: secretKey, sessionToken: token.isEmpty ? nil : token) : nil
                            try store.save(profile: profile, credentials: credentials)
                            clearSecrets(); dismiss()
                        } catch { message = (error as? DebugTransferError)?.localizedDescription ?? "Could not save. Unlock the device and try again." }
                    }.disabled(store.busy)
                    Text("Saving chooses this connection for new transfers. Existing queued recordings keep their destinations. No recordings are sent until you select Send pending.").font(.caption)
                    if let message { Text(message).foregroundStyle(.red) }
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .debugFormStyle()
            .navigationTitle("Save connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { clearSecrets(); dismiss() } }
            .onDisappear { clearSecrets() }
            .onChange(of: phase) { if $0 == .background { clearSecrets(); dismiss() } }
        }
    }
    private func clearSecrets() { accessKey = ""; secretKey = ""; token = "" }
}

/// Shared destination picker + queue action used by both kinds of recording.
struct DebugTransferRecordingButton: View {
    let source: () throws -> DebugTransferSnapshot.Source
    @ObservedObject private var store = DebugTransferStore.shared
    @State private var showTransfers = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.profiles.isEmpty {
                Picker("Destination", selection: Binding(get: { store.selected?.id }, set: { if let id = $0 { store.select(id) } })) {
                    ForEach(store.profiles) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(store.busy)
            }
            Button(store.selected.map { "Queue snapshot → \($0.name)" } ?? "Set up recording transfer") {
                guard let profile = store.selected else { showTransfers = true; return }
                Task {
                    do { try await store.enqueue(source(), profileID: profile.id); showTransfers = true }
                    catch { message = (error as? DebugTransferError)?.localizedDescription ?? "Could not prepare the snapshot. Check local storage and retry." }
                }
            }.disabled(store.busy)
            Button("Connections and transfer queue") { showTransfers = true }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showTransfers) { DebugTransfersView() }
    }
}
#endif
