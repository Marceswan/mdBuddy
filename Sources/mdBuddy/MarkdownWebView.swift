import SwiftUI
import WebKit
import MarkdownKit

/// SwiftUI wrapper around WKWebView that renders the model's markdown file.
/// Re-renders in place on file changes, preserving scroll position; jumps to
/// the top when a different file is opened.
struct MarkdownWebView: NSViewRepresentable {
    @ObservedObject var model: DocumentModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // let CSS paint the bg
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        guard let url = model.currentURL else { return }

        let urlChanged = coord.loadedURL != url
        let versionChanged = coord.loadedVersion != model.version
        guard urlChanged || versionChanged else { return }

        // Preserve scroll only when the same file changed underneath us.
        if !urlChanged && versionChanged {
            webView.evaluateJavaScript("window.scrollY") { value, _ in
                coord.pendingScrollY = (value as? CGFloat)
                coord.render(model: model, webView: webView)
            }
        } else {
            coord.pendingScrollY = nil
            coord.render(model: model, webView: webView)
        }

        coord.loadedURL = url
        coord.loadedVersion = model.version
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var loadedURL: URL?
        var loadedVersion: Int = -1
        var pendingScrollY: CGFloat?

        private let tempHTMLURL: URL = {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mdBuddy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("render.html")
        }()

        func render(model: DocumentModel, webView: WKWebView) {
            guard let url = model.currentURL,
                  let markdown = model.readMarkdown() else { return }
            let baseDir = url.deletingLastPathComponent()
            // Renders Markdown, or a raw Mermaid diagram for .mmd/.mermaid files.
            let html = Renderer.html(forFileAt: url, content: markdown)
            do {
                try html.write(to: tempHTMLURL, atomically: true, encoding: .utf8)
            } catch {
                webView.loadHTMLString(html, baseURL: baseDir)
                return
            }
            // The main resource (render.html) lives in the system temp dir, which
            // is OUTSIDE the markdown's folder. WKWebView refuses to load a main
            // resource that sits outside `allowingReadAccessTo` ("Ignoring request
            // to load this main resource because it is outside the sandbox"), so
            // granting access to baseDir alone leaves the window blank. Grant the
            // filesystem root so both the temp HTML and relative images (resolved
            // from baseDir via <base href>) load. The app is not sandboxed, so this
            // adds no privilege it doesn't already have.
            webView.loadFileURL(tempHTMLURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let y = pendingScrollY {
                pendingScrollY = nil
                webView.evaluateJavaScript("window.scrollTo(0, \(y));")
            }
        }

        // Open external (http/https/mailto) links in the default browser;
        // keep local file navigation inside the app.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            if let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme),
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
