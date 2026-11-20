#if DEBUG && os(iOS)
import SwiftUI

@available(iOS 16.2, *)
struct MotionExperimentView: View {
    @StateObject private var store = MotionExperimentStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newSession = false
    @State private var help = false
    @State private var path: [UUID] = []
    @State private var deletion: MotionExperimentSession?
    @State private var now = Date()
    private var activeSession: MotionExperimentSession? { store.sessions.first { $0.endsAt > now } }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        print("[MotionExperiment] New recording tapped; busy=\(store.busy), active=\(store.active != nil)")
                        newSession = true
                    } label: { Label("New recording", systemImage: "plus.circle.fill") }
                        .accessibilityIdentifier("motion.newRecording")
                    if let activeSession {
                        Text("A session is still recording until \(activeSession.endsAt.formatted(date: .omitted, time: .standard)). Open it to end early.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.busy { ProgressView("Working with session data…") }
                }
                Section("Sessions") {
                    if store.sessions.isEmpty { Text("Record your screen and phone motion, then mark the moments that matter.").foregroundStyle(.secondary) }
                    ForEach(store.sessions) { session in
                        NavigationLink(value: session.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.requestedAt, format: .dateTime.month().day().hour().minute())
                                Text("\(Int(session.duration)) s · \(session.recordsVideo == true ? "Video + motion" : "Motion only")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if session.endsAt > now { Text("Recording · tap to open").font(.caption).foregroundStyle(.orange) }
                            }
                        }.swipeActions {
                            Button("Delete", role: .destructive) { deletion = session }.disabled(session.endsAt > now)
                        }
                    }
                }
                if !store.message.isEmpty { Section { Text(store.message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationDestination(for: UUID.self) { MotionExperimentEditor(sessionID: $0) }
            .task {
                let args = ProcessInfo.processInfo.arguments
                #if targetEnvironment(simulator)
                if args.contains("--motion-new") { newSession = true }
                #endif
                if let index = args.firstIndex(of: "--motion-session"), args.indices.contains(index + 1),
                   let id = UUID(uuidString: args[index + 1]), store.sessions.contains(where: { $0.id == id }) { path = [id] }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) {
                now = $0
                Task { await store.reconcileCaptureEnds() }
            }
            .onAppear { now = Date() }
            .navigationTitle("Scroll motion")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { help = true } label: { Image(systemName: "questionmark.circle") } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $newSession) { MotionNewSessionView() }
            .sheet(isPresented: $help) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Record, review, annotate").font(.title2.bold())
                            Text("Tap Start recording and confirm the system screen broadcast. Video and motion begin together and stop together. Slowth blocking remains active while broadcasting. Video has no audio and stays on this device until you explicitly share it.")
                            Text("Motion-only mode also works. Sensor data can arrive up to 3 minutes later; load it within 3 days. You can review video immediately while waiting.")
                            Text("Tap the timeline to seek. Select a range, drag its handles or enter exact seconds, then add one or more tags. Trim changes the useful interval and never deletes originals. Undo and redo apply to tags, trim and synchronization.")
                            Text("Raw acceleration includes gravity. Missing data is shown as a gap, never as stillness. Motion peaks alone do not prove scrolling.")
                        }.padding()
                    }.navigationTitle("Help").toolbar { Button("Done") { help = false } }
                }
            }
            .alert("Delete this session?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("Cancel", role: .cancel) { deletion = nil }
                Button("Delete", role: .destructive) {
                    if let deletion { do { try store.remove(deletion.id) } catch { store.message = error.localizedDescription } }
                    deletion = nil
                }
            } message: { Text("Deletes local video, imported measurements and edits. Previously queued export copies are managed in Transfers.") }
        }
    }
}

@available(iOS 16.2, *)
private struct MotionNewSessionView: View {
    @ObservedObject private var store = MotionExperimentStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var seconds = 60
    @State private var label = "scroll"
    @State private var video = true
    @State private var frames = false
    @State private var requestedStart = false
    @State private var now = Date()
    private var activeSession: MotionExperimentSession? { store.sessions.first { $0.endsAt > now } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Recording") {
                    Toggle("Save screen video", isOn: $video)
                    Picker("Duration", selection: $seconds) { Text("1 minute").tag(60); Text("3 minutes").tag(180); Text("5 minutes").tag(300) }
                    Picker("Initial tag", selection: $label) { ForEach(MotionExperimentStore.labels, id: \.self) { Text($0).tag($0) } }
                    Text(video
                         ? "Video and motion start together after system confirmation, with no preparation countdown. They stop together when the broadcast ends or the timer expires."
                         : "Motion only: 15 seconds to switch apps and prepare.").font(.footnote)
                }.disabled(store.waitingForBroadcast || store.busy || activeSession != nil)
                Section {
                    if let activeSession {
                        Text("Another session is recording until \(activeSession.endsAt.formatted(date: .omitted, time: .standard)). Open it to stop recording.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("Motion access: \(store.authorization)").font(.footnote)
                    if let activeSession {
                        Button(activeSession.followsBroadcast == true ? "Stop recording" : "End current session", role: .destructive) {
                            Task {
                                do { try await store.mark(sessionID: activeSession.id.uuidString, action: "end") }
                                catch { store.message = error.localizedDescription }
                            }
                        }.disabled(store.busy)
                    } else if video && !frames && !SharedStore.snapshot().broadcastActive {
                        Label("Start recording", systemImage: "record.circle")
                            .foregroundStyle(.blue).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .overlay {
                                BroadcastPickerView(preferredExtensionBundleID: (Bundle.main.bundleIdentifier ?? "") + ".Broadcast",
                                    showsSystemControl: false, accessibilityLabel: "Start video and motion recording",
                                    onActivate: { requestedStart = true; store.prepareLinkedStart(seconds: seconds, label: label) })
                            }
                            .disabled(startDisabled || store.waitingForBroadcast)
                        if !SharedStore.hasRecordingSelection() {
                            Text("Choose at least one app in Slowth before starting its screen broadcast.").font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Button(video ? "Start recording" : "Start motion · 15 s setup") {
                            requestedStart = true
                            if video { store.prepareLinkedStart(seconds: seconds, label: label) }
                            else { Task { await store.start(seconds: seconds, label: label, video: false) } }
                        }.disabled(startDisabled || store.waitingForBroadcast)
                    }
                    if store.waitingForBroadcast {
                        ProgressView("Waiting for screen recording…")
                        Button("Cancel waiting") { store.cancelPendingStart() }
                    } else if store.busy { ProgressView("Starting motion…") }
                    if !store.available { Text("Sensor recording requires a supported physical iPhone.").font(.caption) }
                    if !store.message.isEmpty { Text(store.message).font(.caption) }
                }
            }.navigationTitle("New recording")
                .toolbar { Button("Cancel") { store.cancelPendingStart(); dismiss() } }
                .onAppear { print("[MotionExperiment] New recording setup appeared") }
                .onDisappear { if store.active == nil { store.cancelPendingStart() } }
                .task {
                    while !Task.isCancelled {
                        now = Date()
                        frames = MotionVideoFiles.framesAvailable
                        await store.reconcileCaptureEnds()
                        if requestedStart && store.active != nil && !store.busy && !store.waitingForBroadcast { dismiss(); return }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
        }
    }
    private var startDisabled: Bool { store.busy || activeSession != nil || !store.available || !store.mayRequestMotion }
}
#endif
