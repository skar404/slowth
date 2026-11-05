import SwiftUI
#if canImport(FamilyControls)
import FamilyControls
#endif

#if canImport(FamilyControls)
struct FamilyActivityPickerWrapper: View {
    @State var selection: FamilyActivitySelection
    var appName: String? = nil
    var allowsMultiple = false
    var selectionLockSeconds = 0
    var onDone: ((FamilyActivitySelection) -> Void)?
    var onCancel: (() -> Void)?

    private var exceedsApplicationLimit: Bool {
        allowsMultiple && !BlockingRules.supportsApplicationCount(selection.applicationTokens.count)
    }

    private var invalidGroupSelection: Bool {
        allowsMultiple && !selection.categoryTokens.isEmpty && (!selection.includeEntireCategory || selection.applicationTokens.isEmpty)
    }

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $selection)
                .disabled(selectionLockSeconds > 0)
                .safeAreaInset(edge: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        if selectionLockSeconds > 0 {
                            HStack {
                                Text(String(localized: "Pause", table: "Interface"))
                                Text(String(format: "%d:%02d", selectionLockSeconds / 60, selectionLockSeconds % 60))
                                    .monospacedDigit()
                            }
                            .font(.headline)
                            .accessibilityIdentifier("apps.selection.pause")
                        }
                        if allowsMultiple {
                            Text(String(format: String(localized: "Select up to %d apps to enable blocking.", table: "Interface"),
                                        BlockingRules.maximumSelectedApplications))
                                .foregroundStyle(exceedsApplicationLimit ? Color.red : Color.primary)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("apps.selection.limit")
                            Text(verbatim: "\(selection.applicationTokens.count) / \(BlockingRules.maximumSelectedApplications)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(exceedsApplicationLimit ? Color.red : Color.secondary)
                        }
                        Text(invalidGroupSelection ? String(localized: "Could not expand this category. Select individual apps.", table: "Interface") : allowsMultiple ? String(localized: "Choose apps or categories. Only apps are saved; websites are ignored. Reselect a category after installing new apps.", table: "Interface") : appName.map {
                            String(format: String(localized: "Tap Search below, enter %@, and select the app.", table: "Interface"), $0)
                        } ?? AppLocalization.string("Pick a single app, not a whole category or \"All Apps\" — that would block everything."))
                            .foregroundStyle(invalidGroupSelection ? Color.red : Color.primary)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
                .navigationTitle(allowsMultiple ? String(localized: "Selected apps", table: "Interface") : appName.map {
                    String(format: String(localized: "Choose %@", table: "Interface"), $0)
                } ?? String(localized: "Block apps"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { onCancel?() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { onDone?(selection) }
                            .disabled(invalidGroupSelection || exceedsApplicationLimit || selectionLockSeconds > 0)
                    }
                }
        }
    }
}
#endif

#if DEBUG && canImport(FamilyControls)
#Preview("Choose apps") {
    FamilyActivityPickerWrapper(selection: FamilyActivitySelection())
}
#endif

#if DEBUG && os(iOS) && canImport(FamilyControls)
import UIKit
import ManagedSettings

/// Explicit, local-only experiment. Captures only this diagnostic stage, never
/// the device screen. Does not read token internals or change blocking settings.
struct FamilyIconProbeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = "Ожидание загрузки системных иконок…"
    private let tokens: [ApplicationToken] = Array((GroupedApps.selection?.applicationTokens ?? []).prefix(3))

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Сверху — контрольная картинка. Ниже — системные иконки и названия выбранных приложений.")
                        .font(.footnote)
                    FamilyIconProbeHost(tokens: tokens, report: $report)
                        .frame(width: 320, height: 340)
                        .border(Color.gray)
                    Text(report).font(.caption.monospaced()).textSelection(.enabled)
                }.padding()
            }
            .navigationTitle("Эксперимент с иконками")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

private struct FamilyIconProbeStage: View {
    let tokens: [ApplicationToken]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("CONTROL", systemImage: "checkmark.square.fill")
                .foregroundStyle(.green)
                .font(.title2)
                .frame(height: 48)
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                HStack(spacing: 16) {
                    Text("\(index + 1)").font(.caption.monospaced())
                    Label(token).labelStyle(.titleAndIcon)
                        .font(.title2)
                }
                .frame(height: 56)
            }
            if tokens.isEmpty { Text("Сначала выберите приложения в общем списке.") }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 320, height: 340, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }
}

private struct FamilyIconProbeHost: UIViewControllerRepresentable {
    let tokens: [ApplicationToken]
    @Binding var report: String
    func makeUIViewController(context: Context) -> FamilyIconProbeController {
        FamilyIconProbeController(tokens: tokens) { report = $0 }
    }
    func updateUIViewController(_ controller: FamilyIconProbeController, context: Context) {}
}

private final class FamilyIconProbeController: UIViewController {
    let tokens: [ApplicationToken]
    let onReport: (String) -> Void
    private var host: UIHostingController<FamilyIconProbeStage>!
    private var captureTask: Task<Void, Never>?
    private let runID = UUID().uuidString

    init(tokens: [ApplicationToken], onReport: @escaping (String) -> Void) {
        self.tokens = tokens
        self.onReport = onReport
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        host = UIHostingController(rootView: FamilyIconProbeStage(tokens: tokens))
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 340)
        host.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard captureTask == nil else { return }
        captureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.capture(round: "2s")
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self.capture(round: "8s")
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        captureTask?.cancel()
    }
    private func capture(round: String) {
        guard view.window != nil, UIApplication.shared.applicationState == .active else {
            onReport("Экран не активен. Откройте эксперимент ещё раз.")
            return
        }
        do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("IconProbe/" + runID, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            host.view.layoutIfNeeded()
            let bounds = host.view.bounds
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
            var complete = false
            let hierarchy = renderer.image { _ in
                complete = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            let layer = renderer.image { context in
                UIColor.white.setFill()
                context.fill(bounds)
                host.view.layer.render(in: context.cgContext)
            }
            let swiftUI = ImageRenderer(content: FamilyIconProbeStage(tokens: tokens))
            swiftUI.scale = 2
            swiftUI.proposedSize = ProposedViewSize(width: 320, height: 340)
            var files = [String]()
            for (method, image) in [("hierarchy", Optional(hierarchy)), ("layer", Optional(layer)), ("swiftui", swiftUI.uiImage)] {
                if let png = image?.pngData() {
                    let name = round + "-" + method + ".png"
                    try png.write(to: root.appendingPathComponent(name), options: .atomic)
                    files.append(name)
                }
            }
            let metadata: [String: Any] = ["run": runID, "round": round, "tokenCount": tokens.count,
                "hierarchyComplete": complete, "onScreen": host.view.window != nil,
                "os": UIDevice.current.systemVersion, "files": files,
                "note": "A true hierarchy result is not proof that system icon pixels were captured. Inspect PNGs against CONTROL."]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent(round + "-report.json"), options: .atomic)
            onReport("Раунд \(round): сохранено \(files.count) PNG.\nИконок: \(tokens.count). drawHierarchy: \(complete).\nDocuments/IconProbe/\(runID)\n\nНаличие иконок проверим по самим PNG.")
        } catch { onReport(error.localizedDescription) }
    }
}
#endif

#if DEBUG && os(iOS) && canImport(FamilyControls)
/// Read-only picker experiment. Never commits a selection to blocking settings.
struct FamilyCategoryProbeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var report: String?
    @State private var includeContents = true

    var body: some View {
        NavigationStack {
            if let report {
                List {
                    Text(report).font(.body.monospaced())
                    ForEach(Array(selection.applicationTokens), id: \.self) { Label($0) }
                    Button("Повторить с другим режимом") {
                        includeContents.toggle()
                        selection = FamilyActivitySelection(includeEntireCategory: includeContents)
                        self.report = nil
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { dismiss() } } }
            } else {
                FamilyActivityPicker(selection: $selection)
                    .safeAreaInset(edge: .top) {
                        Text("Выберите целиком «Социальные сети». Настройки блокировки не изменятся. includeEntireCategory = \(includeContents.description)")
                            .font(.footnote).padding()
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { finish() } } }
            }
        }
    }
    private func finish() {
        let values: [String: Any] = ["includeEntireCategory": selection.includeEntireCategory,
            "applications": selection.applicationTokens.count, "categories": selection.categoryTokens.count,
            "webDomains": selection.webDomainTokens.count, "os": UIDevice.current.systemVersion]
        do {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CategoryProbe")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent(includeContents ? "include-true.json" : "include-false.json"), options: .atomic)
            report = "Приложения: \(selection.applicationTokens.count)\nКатегории: \(selection.categoryTokens.count)\nСайты: \(selection.webDomainTokens.count)\nincludeEntireCategory: \(selection.includeEntireCategory)"
        } catch { report = error.localizedDescription }
    }
}
#endif
