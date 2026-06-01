import Cocoa
import WebKit
import Quartz
import os
import MarkdownKit

private let log = Logger(subsystem: "com.mdbuddy.app.quicklook", category: "preview")

/// Quick Look preview extension principal class. Renders the selected Markdown
/// file (with Mermaid + highlighting) into a WKWebView, the same way the main
/// app does, and signals Quick Look once rendering is complete.
///
/// Registered via Info.plist: NSExtensionPrincipalClass = "PreviewViewController",
/// NSExtensionPointIdentifier = com.apple.quicklook.preview.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController,
                                   WKScriptMessageHandler, WKNavigationDelegate {

    private var webView: WKWebView!
    private var readyHandler: ((Error?) -> Void)?
    private var fallbackTimer: Timer?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: Renderer.readyMessageName)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        self.webView = webView
        self.view = webView
    }

    // MARK: QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let markdown: String
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            markdown = text
        } else if let data = try? Data(contentsOf: url) {
            markdown = String(decoding: data, as: UTF8.self)
        } else {
            handler(NSError(domain: "mdBuddy.quicklook", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.lastPathComponent)"]))
            return
        }

        log.notice("preparePreviewOfFile: \(url.lastPathComponent, privacy: .public) (\(markdown.count) chars)")
        readyHandler = handler
        // Renders Markdown, or a raw Mermaid diagram for .mmd/.mermaid files.
        let html = Renderer.html(forFileAt: url, content: markdown)

        // baseURL MUST be nil here. The extension sandbox is granted access to
        // the previewed file only, NOT its directory, so a file:// baseURL
        // pointing at that directory makes WebKit block the whole load and the
        // preview comes up blank. All vendor JS/CSS is inlined, so no base is
        // needed; the trade-off is that relative-path images won't resolve.
        webView.loadHTMLString(html, baseURL: nil)

        // Safety net: if the page never posts the ready message, don't hang.
        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            log.notice("fallback timer fired; completing preview")
            self?.finish()
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    // MARK: WKNavigationDelegate (diagnostics + completion backstop)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.notice("navigation didFinish")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("navigation didFail: \(error.localizedDescription, privacy: .public)")
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        finish()
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == Renderer.readyMessageName {
            log.notice("page reported ready; completing preview")
            finish()
        }
    }

    private func finish() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        let handler = readyHandler
        readyHandler = nil
        handler?(nil)
    }
}
