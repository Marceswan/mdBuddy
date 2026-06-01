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

        /// The last on-disk render file we wrote, so we can remove it when the
        /// open file changes or the view goes away.
        private var lastRenderURL: URL?

        func render(model: DocumentModel, webView: WKWebView) {
            guard let url = model.currentURL,
                  let markdown = model.readMarkdown() else { return }
            let baseDir = url.deletingLastPathComponent()
            // Renders Markdown, or a raw Mermaid diagram for .mmd/.mermaid files.
            let html = Renderer.html(forFileAt: url, content: markdown)

            // Write the rendered HTML INTO the markdown's own folder. WKWebView
            // refuses to load a main resource that sits outside the
            // `allowingReadAccessTo` subtree, so keeping it in baseDir lets us
            // grant access to baseDir ALONE rather than the whole filesystem.
            // That scopes the web view's file reach to the one folder the user
            // opened (defense in depth: a malicious markdown can't read arbitrary
            // local files) while relative images still resolve. Falls back to an
            // in-memory load (no relative images) when the folder isn't writable.
            let renderURL = baseDir.appendingPathComponent(".mdBuddy-preview.html")
            removeRenderFile()  // clear any prior file, possibly in another folder
            do {
                try html.write(to: renderURL, atomically: true, encoding: .utf8)
                lastRenderURL = renderURL
                webView.loadFileURL(renderURL, allowingReadAccessTo: baseDir)
            } catch {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        /// Delete the on-disk render file we last wrote (best effort).
        func removeRenderFile() {
            if let prior = lastRenderURL {
                try? FileManager.default.removeItem(at: prior)
                lastRenderURL = nil
            }
        }

        deinit { removeRenderFile() }

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
