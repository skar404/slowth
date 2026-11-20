#if DEBUG && os(iOS)
import AVKit
import SwiftUI

@available(iOS 16.2, *)
struct MotionExperimentEditor: View {
    let sessionID: UUID
    @ObservedObject private var store = MotionExperimentStore.shared
    @StateObject private var playback = MotionExperimentPlayer()
    @State private var history: MotionEditHistory?
    @State private var video: MotionVideoManifest?
    @State private var selection: MotionTimeRange?
    @State private var vertical = ProcessInfo.processInfo.arguments.contains("--motion-vertical")
    @State private var zoom = 16.0
    @State private var rate: Float = 1
    @State private var actions = false
    @State private var tags = false
    @State private var error = ""
    @State private var exporting = false
    @State private var now = Date()
    @State private var motionAxes = MotionAxes.empty
    private var session: MotionExperimentSession? { store.sessions.first { $0.id == sessionID } }
    private var edits: MotionExperimentEdits? { history?.value }
    private var samples: [MotionExperimentSample] { store.loadedID == sessionID ? store.samples : [] }
    private var active: Bool { (session?.endsAt ?? .distantPast) > now }

    var body: some View {
        VStack(spacing: 8) {
            if let session, let edits {
                videoPanel(edits)
                playbackControls(edits)
                if active {
                    HStack {
                        Text(now < session.startsAt ? "Setup" : "Recording")
                        Text(timerInterval: session.requestedAt...session.endsAt, countsDown: true).monospacedDigit()
                        Button(session.followsBroadcast == true ? "Stop recording" : "End") { Task { do { try await store.mark(sessionID: sessionID.uuidString, action: "end") } catch { self.error = error.localizedDescription } } }
                    }.font(.subheadline).padding(.horizontal)
                }
                HStack {
                    Picker("Timeline direction", selection: $vertical) {
                        Image(systemName: "arrow.left.and.right").tag(false)
                        Image(systemName: "arrow.up.and.down").tag(true)
                    }.pickerStyle(.segmented).frame(width: 110)
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $zoom, in: 4...100).accessibilityLabel("Timeline zoom")
                    Image(systemName: "plus.magnifyingglass")
                    Button("Select") { selection = .init(start: playback.position, end: min(edits.trim.end, playback.position + 5)) }
                }.padding(.horizontal)
                HStack(spacing: 12) {
                    Text("X").foregroundStyle(.red)
                    Text("Y").foregroundStyle(.green)
                    Text("Z").foregroundStyle(.blue)
                    Text("±\(motionAxes.limit, specifier: "%.1f") g").foregroundStyle(.secondary)
                    Spacer()
                    if samples.isEmpty {
                        Button(store.busy ? "Loading motion…" : "Load motion") { Task { await store.load(sessionID, fetch: true) } }
                            .disabled(store.busy)
                    }
                }.font(.caption.monospacedDigit()).padding(.horizontal)
                MotionExperimentTimeline(session: session, axes: motionAxes, edits: edits,
                    thumbnails: playback.thumbnails, vertical: vertical, zoom: zoom,
                    position: playback.position, playing: playback.playing, selection: $selection, seek: { playback.seek($0) })
                    .frame(maxHeight: .infinity)
                if selection != nil { selectionPanel(edits, duration: session.duration).disabled(active) }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
                if !playback.message.isEmpty { Text(playback.message).font(.caption).foregroundStyle(.red) }
            } else {
                ProgressView("Opening session…")
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Session editor").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { changeHistory(undo: true) } label: { Image(systemName: "arrow.uturn.backward") }.disabled(history?.canUndo != true || active)
                Button { changeHistory(undo: false) } label: { Image(systemName: "arrow.uturn.forward") }.disabled(history?.canRedo != true || active)
                Button { actions = true } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $actions) { actionsPanel }
        .sheet(isPresented: $tags) {
            if let edits {
                MotionTagManager(tags: edits.tags) { updated in
                    var next = history!.value; next.tags = updated; commit(next)
                }
            }
        }
        .onChange(of: samples.count) { _ in refreshBins() }
        .onChange(of: rate) { playback.setRate($0) }
        .onDisappear { playback.close() }
        .task {
            await store.reconcileCaptureEnds()
            guard let session else { return }
            do { history = MotionEditHistory(value: try store.edits(for: session)) }
            catch { self.error = "Edits could not be read; original files were preserved. \(error.localizedDescription)"; return }
            await store.load(sessionID, fetch: false)
            refreshBins()
            video = store.video(for: sessionID)
            await playback.configure(session: session, video: video, edits: history!.value)
            // Video is already ready; the delayed Core Motion query runs independently.
            if store.canAutomaticallyLoadMotion { Task { await store.load(sessionID, fetch: true) } }
            #if targetEnvironment(simulator)
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--motion-selection"), args.indices.contains(index + 2),
               let start = Double(args[index + 1]), let end = Double(args[index + 2]) {
                selection = MotionTimeRange(start: start, end: end).clamped(to: session.duration)
                playback.seek(start)
            }
            #endif
            var wasActive = active
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await store.reconcileCaptureEnds()
                now = Date()
                let updatedVideo = store.video(for: sessionID)
                if let session = self.session, wasActive && !active {
                    do { history = MotionEditHistory(value: try store.edits(for: session)) }
                    catch { self.error = error.localizedDescription }
                }
                if updatedVideo != video || (wasActive && !active), let session = self.session, let edits {
                    video = updatedVideo
                    await playback.configure(session: session, video: video, edits: edits)
                }
                wasActive = active
            }
        }
    }
    private func refreshBins() {
        guard let session else { return }
        motionAxes = MotionExperimentAnalysis.axes(samples, session: session)
    }
    private func videoPanel(_ edits: MotionExperimentEdits) -> some View {
        ZStack {
            Color.black
            VideoPlayer(player: playback.player).allowsHitTesting(false)
            if video?.segment(at: playback.position, offset: edits.videoOffset) == nil {
                Color.black
                Label(video == nil ? "No video · motion session" : "No video at this time", systemImage: "video.slash")
                    .foregroundStyle(.white).font(.caption)
            }
        }.frame(height: vertical ? 160 : 190).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
    }
    private func playbackControls(_ edits: MotionExperimentEdits) -> some View {
        HStack(spacing: 16) {
            Button { playback.step(-1) } label: { Image(systemName: "backward.frame") }.accessibilityLabel("Previous frame")
            Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill") }.accessibilityLabel("Play or pause")
            Button { playback.step(1) } label: { Image(systemName: "forward.frame") }.accessibilityLabel("Next frame")
            Text(String(format: "%.2f / %.1f s", playback.position, edits.trim.end)).font(.caption.monospacedDigit())
            Picker("Speed", selection: $rate) { Text("0.25×").tag(Float(0.25)); Text("0.5×").tag(Float(0.5)); Text("1×").tag(Float(1)) }
                .labelsHidden().frame(maxWidth: 95)
        }.buttonStyle(.borderless)
    }
    private func selectionPanel(_ edits: MotionExperimentEdits, duration: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selection").font(.caption.bold())
                TextField("Start", value: rangeBinding(start: true, duration: duration), format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityLabel("Selection start seconds")
                Text("–")
                TextField("End", value: rangeBinding(start: false, duration: duration), format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityLabel("Selection end seconds")
                Button { selection = nil } label: { Image(systemName: "xmark.circle") }
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(edits.tags) { tag in
                        Button(tag.name) {
                            guard let selection else { return }
                            var next = edits; next.assign(tag.id, to: selection); commit(next)
                        }.tint(motionTagColor(tag.color)).buttonStyle(.bordered)
                    }
                    Button { tags = true } label: { Image(systemName: "plus") }.accessibilityLabel("Manage tags")
                }
            }
            HStack {
                Button("Trim to selection") {
                    guard let selection, selection.end > selection.start else { return }
                    var next = edits; next.trim = selection; commit(next)
                }
                Spacer()
                Button("Full range") { var next = edits; next.trim = .init(start: 0, end: duration); commit(next) }
            }.font(.caption)
            let matching = edits.intervals.filter { interval in
                guard let selection else { return false }
                return interval.range.start < selection.end && interval.range.end > selection.start
            }
            if !matching.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(matching) { interval in
                            HStack(spacing: 6) {
                                Button { selection = interval.range } label: {
                                    Text("\(edits.tags.first { $0.id == interval.tagID }?.name ?? "Tag") \(interval.range.start, specifier: "%.1f")–\(interval.range.end, specifier: "%.1f")")
                                }
                                Button { if let selection { var next = edits; if let i = next.intervals.firstIndex(where: { $0.id == interval.id }) { next.intervals[i].range = selection }; commit(next) } } label: { Image(systemName: "arrow.left.and.right") }
                                    .accessibilityLabel("Set interval to selection")
                                Button { var next = edits; next.intervals.removeAll { $0.id == interval.id }; commit(next) } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove interval")
                            }.font(.caption).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }.padding(10).background(.thinMaterial)
    }
    private func rangeBinding(start: Bool, duration: Double) -> Binding<Double> {
        Binding(get: { start ? selection?.start ?? 0 : selection?.end ?? 0 }, set: { value in
            guard var range = selection, value.isFinite else { return }
            if start { range.start = min(range.end, max(0, value)) }
            else { range.end = max(range.start, min(duration, value)) }
            selection = range
        })
    }
    private func commit(_ next: MotionExperimentEdits) {
        guard var history else { return }
        do {
            try store.saveEdits(next, id: sessionID)
            let syncChanged = history.value.videoOffset != next.videoOffset
            history.apply(next); self.history = history; error = ""
            playback.trim = next.trim; playback.seek(playback.position)
            if syncChanged, let session { Task { await playback.configure(session: session, video: video, edits: next) } }
        } catch { self.error = "Edits were not saved: \(error.localizedDescription)" }
    }
    private func changeHistory(undo: Bool) {
        guard var history else { return }
        if undo { history.undo() } else { history.redo() }
        do {
            try store.saveEdits(history.value, id: sessionID)
            self.history = history
            if let session { Task { await playback.configure(session: session, video: video, edits: history.value) } }
        } catch { self.error = error.localizedDescription }
    }
    private var actionsPanel: some View {
        NavigationStack {
            Form {
                Section("Data and capture") {
                    Text("\(samples.count) motion samples")
                    if let session {
                        Text("Largest missing motion interval: \(MotionExperimentAnalysis.largestGap(samples, start: session.startsAt, end: session.endsAt), specifier: "%.2f") s")
                    }
                    Text("Video: \(video?.state ?? "not recorded") · \(video?.segments.count ?? 0) segments")
                    if let reason = video?.reason { Text(reason).foregroundStyle(.orange) }
                    Text("Encoder back-pressure drops: \(video?.droppedFrames ?? 0)").font(.caption)
                    Button("Load recorded sensor data") { Task { await store.load(sessionID, fetch: true) } }.disabled(store.busy)
                    Text(store.message).font(.caption)
                }
                if let edits {
                    Section("Synchronization") {
                        TextField("Video offset (seconds)", value: Binding(get: { edits.videoOffset }, set: { value in
                            guard value.isFinite else { return }
                            var next = edits; next.videoOffset = min(60, max(-60, value)); commit(next)
                        }), format: .number.precision(.fractionLength(3))).keyboardType(.numbersAndPunctuation).disabled(active)
                        Text("Positive values move video later. Raw frame PTS, arrival uptime and sensor timestamps are preserved. Arrival anchoring has capture latency; verify alignment at the start and end.").font(.caption)
                    }
                }
                Section("Export") {
                    Button("Prepare trimmed CSV") { store.export(sessionID) }
                    Button("Prepare full session ZIP") { Task { await store.exportFull(sessionID) } }
                    Button("Export trimmed video clip") {
                        exporting = true
                        Task {
                            defer { exporting = false }
                            do { store.exportURL = try await playback.exportClip() }
                            catch { store.message = error.localizedDescription }
                        }
                    }.disabled(video?.segments.isEmpty != false)
                    if exporting { ProgressView("Exporting clip…") }
                    if let url = store.exportURL { ShareLink("Share export", item: url) }
                    DebugTransferRecordingButton { try store.transferSource(sessionID) }
                    Text("Full exports include originals and edits. Clips preserve gaps as black video. Transfer only starts from the transfer queue after you choose Send pending.").font(.caption)
                }.disabled(active || exporting)
            }.navigationTitle("Session actions").toolbar { Button("Done") { actions = false } }
        }
    }
}

func motionTagColor(_ name: String) -> Color {
    switch name {
    case "green": return .green
    case "orange": return .orange
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "teal": return .teal
    default: return .blue
    }
}

private struct MotionTagManager: View {
    @Environment(\.dismiss) private var dismiss
    @State var tags: [MotionTag]
    let save: ([MotionTag]) -> Void
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form {
                ForEach($tags) { $tag in
                    HStack {
                        TextField("Tag name", text: $tag.name)
                        Picker("Color", selection: $tag.color) { ForEach(MotionTag.colors, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    }
                }
                HStack {
                    TextField("New tag", text: $name)
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { tags.append(.init(name: trimmed, color: MotionTag.colors[tags.count % MotionTag.colors.count])); name = "" }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.navigationTitle("Tags")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save(tags); dismiss() }.disabled(tags.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
                }
        }
    }
}
#endif
