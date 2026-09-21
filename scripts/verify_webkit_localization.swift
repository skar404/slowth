// Exercise WebKit's real WebExtension locale selection, not a getMessage stub.
// macOS 15.4+, compile with: xcrun swiftc -parse-as-library -o /tmp/slowth-webkit-l10n scripts/verify_webkit_localization.swift
// Run each locale in a fresh process (AppleLanguages is process-local):
// /tmp/slowth-webkit-l10n /path/to/WebExt ar /tmp/slowth-l10n-qa 320 blocked -AppleLanguages '(ar)'
import AppKit
import WebKit

@main
struct LocalizationCheck {
    @MainActor static var webView: WKWebView!
    @MainActor static var controller: WKWebExtensionController!
    @MainActor static var context: WKWebExtensionContext!
    @MainActor static var navigation: Navigation!

    @MainActor final class Navigation: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Error>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume(); continuation = nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error); continuation = nil
        }
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
            fputs("FAIL: WebKit timeout\n", stderr); exit(2)
        }
        NSApplication.shared.run()
    }

    @MainActor static func check() async throws {
        let args = CommandLine.arguments
        guard args.count >= 6 else { fatalError("Expected resource directory, locale, output directory, width and page") }
        let expected = args[2], output = URL(fileURLWithPath: args[3], isDirectory: true)
        let width = Double(args[4])!, page = args[5]
        let ext = try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: args[1], isDirectory: true))
        guard ext.errors.isEmpty else { throw ext.errors[0] }
        controller = WKWebExtensionController(configuration: .nonPersistent())
        context = WKWebExtensionContext(for: ext)
        try controller.load(context)
        let config = context.webViewConfiguration!
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1100), configuration: config)
        navigation = Navigation()
        webView.navigationDelegate = navigation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation.continuation = continuation
            webView.load(URLRequest(url: URL(string: "\(page).html?host=youtube", relativeTo: context.baseURL)!))
        }
        // Show the whole guide for layout review; locale resolution remains native WebKit.
        if page == "app" {
            _ = try await webView.evaluateJavaScript("document.body.classList.add('landing'); document.getElementById('onboarding').classList.remove('hidden')")
        }
        let result = try await webView.evaluateJavaScript("""
        JSON.stringify({locale: browser.i18n.getMessage('locale'), ui: browser.i18n.getUILanguage(),
          lang: document.documentElement.lang, dir: document.documentElement.dir,
          title: document.title, duration: Unscroll.i18n.duration(61000),
          width: innerWidth, scrollWidth: document.documentElement.scrollWidth,
          text: document.getElementById('blocked-title')?.textContent || document.querySelector('[data-i18n=strictMode]').textContent})
        """) as! String
        print(result)
        let data = Data(result.utf8)
        let values = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard values["locale"] as? String == expected, values["lang"] as? String == expected else {
            throw NSError(domain: "Locale selection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected \(expected): \(result)"])
        }
        let rtl = ["ar", "ar-EG", "he", "ur", "pa-Arab"].contains(expected)
        guard values["dir"] as? String == (rtl ? "rtl" : "ltr") else { fatalError("Incorrect direction") }
        guard (values["scrollWidth"] as! Int) <= Int(width) else { fatalError("Horizontal overflow: \(result)") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(expected)-\(page)-\(Int(width)).json"))
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        let png = NSBitmapImageRep(data: snapshot.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent("\(expected)-\(page)-\(Int(width)).png"))
    }
}
