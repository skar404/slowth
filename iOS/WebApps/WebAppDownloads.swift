import SwiftUI
import WebKit
import QuickLook
import UniformTypeIdentifiers

@available(iOS 18.4, *)
@MainActor
final class WebAppDownloads: NSObject, ObservableObject, WKDownloadDelegate {
    struct Item: Identifiable {
        let id: ObjectIdentifier
        var name = String(localized: "Download", table: "WebApps")
        var progress: Double = 0
        var url: URL?
        var complete = false
        var error: String?
    }
    @Published private(set) var items: [Item] = []
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    func add(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        downloads[id] = download
        items.append(Item(id: id))
        download.delegate = self
        observations[id] = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in self?.update(id) { $0.progress = value } }
        }
    }
    private func update(_ id: ObjectIdentifier, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }
    func cancel(_ id: ObjectIdentifier) {
        downloads[id]?.cancel { [weak self] _ in self?.remove(id) }
    }
    func clear() async {
        for item in items {
            if let download = downloads[item.id] {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    download.cancel { _ in continuation.resume() }
                }
            }
            remove(item.id)
        }
    }
    func remove(_ id: ObjectIdentifier) {
        if let url = items.first(where: { $0.id == id })?.url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        observations[id] = nil; downloads[id] = nil
        items.removeAll { $0.id == id }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        do {
            // A separate random directory avoids overwrites and path traversal by server filenames.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SlowthDownloads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let leaf = (suggestedFilename as NSString).lastPathComponent
            let name = leaf.isEmpty || leaf == "." || leaf == ".." ? "download" : leaf
            let url = directory.appendingPathComponent(name)
            update(ObjectIdentifier(download)) { $0.url = url; $0.name = name }
            completionHandler(url)
        } catch { completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        update(id) { $0.complete = true; $0.progress = 1 }
        observations[id] = nil; downloads[id] = nil
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        #if DEBUG
        print("[WebApps] download error: \((error as NSError).domain) \((error as NSError).code)")
        #endif
        let id = ObjectIdentifier(download)
        update(id) { $0.error = String(localized: "Download failed. Try again on the website.", table: "WebApps") }
        observations[id] = nil; downloads[id] = nil
    }
}

@available(iOS 18.4, *)
struct WebAppDownloadsScreen: View {
    @ObservedObject var downloads: WebAppDownloads
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var previewURL: URL?
    var body: some View {
        NavigationStack {
            List {
                if downloads.items.isEmpty { Text(String(localized: "No downloads", table: "WebApps")) }
                ForEach(downloads.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name).lineLimit(2)
                        if let error = item.error {
                            Text(error).foregroundStyle(.secondary)
                            Button(String(localized: "Remove", table: "WebApps")) { downloads.remove(item.id) }
                        } else if item.complete, let url = item.url {
                            Button(String(localized: "Save to Files", table: "WebApps")) { exportURL = url }
                            if url.pathExtension.lowercased() == "pdf" {
                                Button(String(localized: "Preview PDF", table: "WebApps")) { previewURL = url }
                            }
                            Button(String(localized: "Remove", table: "WebApps")) { downloads.remove(item.id) }
                        } else {
                            ProgressView(value: item.progress)
                            Button(String(localized: "Cancel")) { downloads.cancel(item.id) }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Downloads", table: "WebApps"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Close")) { dismiss() } } }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL { WebAppFileExporter(url: exportURL) }
            }
            .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
                if let previewURL { WebAppPDFPreview(url: previewURL) }
            }
        }
    }
}

private struct WebAppFileExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// Local Quick Look renders a completed PDF without giving it a site's cookies or JavaScript context.
private struct WebAppPDFPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
