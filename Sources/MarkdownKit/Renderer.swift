import Foundation

/// Builds a self-contained HTML document that renders a markdown string with
/// markdown-it, syntax highlighting (highlight.js), and inline Mermaid diagrams.
/// All vendor JS/CSS is inlined so the page has zero network dependencies.
public enum Renderer {

    /// Name of the WKScriptMessageHandler the page notifies once rendering
    /// (including Mermaid) is complete. Hosts that must wait before snapshotting
    /// the view (Quick Look) register a handler under this name; the main app
    /// simply does not, and the page's postMessage is silently ignored.
    public static let readyMessageName = "mdReady"

    /// Cached vendor asset contents (read once from the bundle).
    private static let vendor: [String: String] = loadVendor()

    /// Marker class used only to resolve the bundle MarkdownKit is linked into.
    private final class ResourceMarker {}

    /// Locate the `vendor` directory of inlined JS/CSS. Packaged builds (app and
    /// the Quick Look .appex) carry it at `Contents/Resources/vendor`, found via
    /// `Bundle.main.resourceURL`. Only `swift run` falls back to `Bundle.module`
    /// — whose generated accessor `fatalError`s if the bundle is missing, so it
    /// is evaluated lazily and never touched when a directory is already found
    /// (this is what kept the sandboxed extension from crashing).
    private static func vendorDirectory() -> URL? {
        let probe = "markdown-it.min.js"
        var bases: [URL] = []
        if let r = Bundle.main.resourceURL { bases.append(r) }
        if let r = Bundle(for: ResourceMarker.self).resourceURL { bases.append(r) }
        for base in bases {
            let dir = base.appendingPathComponent("vendor", isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(probe).path) {
                return dir
            }
        }
        if let url = Bundle.module.url(forResource: "markdown-it.min", withExtension: "js", subdirectory: "vendor") {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    private static func loadVendor() -> [String: String] {
        guard let dir = vendorDirectory() else { return [:] }
        let names = [
            "markdown-it.min.js",
            "markdown-it-task-lists.min.js",
            "highlight.min.js",
            "mermaid.min.js",
            "github-markdown.css",
            "hljs-github.css",
            "hljs-github-dark.css"
        ]
        var out: [String: String] = [:]
        for name in names {
            if let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                out[name] = text
            }
        }
        return out
    }

    /// File extensions whose contents are a raw Mermaid diagram (no Markdown),
    /// e.g. a `.mmd` file holding only `graph TD; A-->B`.
    public static let mermaidExtensions: Set<String> = ["mmd", "mermaid"]

    /// Build an HTML document for a file on disk, picking the pipeline by
    /// extension: `.mmd`/`.mermaid` are raw Mermaid diagrams (wrapped in a fenced
    /// mermaid block so the standard pipeline renders them as inline SVG);
    /// everything else is treated as Markdown.
    public static func html(forFileAt url: URL, content: String) -> String {
        let baseDirectory = url.deletingLastPathComponent()
        if mermaidExtensions.contains(url.pathExtension.lowercased()) {
            return htmlForMermaidDiagram(content, baseDirectory: baseDirectory)
        }
        return html(markdown: content, baseDirectory: baseDirectory)
    }

    /// Wrap a raw Mermaid diagram in a fenced ```mermaid block and render it
    /// through the standard Markdown pipeline. Uses a long (5-backtick) fence so
    /// a diagram body that itself contains backticks cannot break out.
    public static func htmlForMermaidDiagram(_ diagram: String, baseDirectory: URL) -> String {
        let fence = "`````"
        let wrapped = "\(fence)mermaid\n\(diagram)\n\(fence)\n"
        return html(markdown: wrapped, baseDirectory: baseDirectory)
    }

    /// Produce a complete HTML document for the given markdown.
    /// - Parameters:
    ///   - markdown: raw markdown text.
    ///   - baseDirectory: directory the markdown file lives in, used as the
    ///     document base so relative image/link paths resolve correctly.
    public static func html(markdown: String, baseDirectory: URL) -> String {
        let mdJSON = jsonString(markdown)
        let baseHref = baseDirectory.absoluteString  // file:///.../ with trailing slash

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <base href="\(escapeAttr(baseHref))">
        <style>
        \(vendor["github-markdown.css"] ?? "")
        </style>
        <style media="(prefers-color-scheme: light)">
        \(vendor["hljs-github.css"] ?? "")
        </style>
        <style media="(prefers-color-scheme: dark)">
        \(vendor["hljs-github-dark.css"] ?? "")
        </style>
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; }
        body {
            background: var(--bgColor-default, Canvas);
            -webkit-font-smoothing: antialiased;
        }
        .markdown-body {
            box-sizing: border-box;
            max-width: 900px;
            margin: 0 auto;
            padding: 32px 44px 96px;
        }
        .markdown-body pre.mermaid {
            background: transparent;
            padding: 0;
            text-align: center;
            overflow-x: auto;
        }
        .mermaid-error {
            border: 1px solid var(--borderColor-danger-emphasis, #cf222e);
            color: var(--fgColor-danger, #cf222e);
            border-radius: 6px;
            padding: 8px 12px;
            font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
            white-space: pre-wrap;
        }
        </style>
        </head>
        <body>
        <article id="content" class="markdown-body"></article>

        <script>\(vendor["markdown-it.min.js"] ?? "")</script>
        <script>\(vendor["markdown-it-task-lists.min.js"] ?? "")</script>
        <script>\(vendor["highlight.min.js"] ?? "")</script>
        <script>\(vendor["mermaid.min.js"] ?? "")</script>

        <script>
        (function () {
            "use strict";
            var MD_SOURCE = \(mdJSON);

            var md = window.markdownit({
                html: true,
                linkify: true,
                typographer: true,
                highlight: function (code, lang) {
                    if (lang && window.hljs && window.hljs.getLanguage(lang)) {
                        try {
                            return window.hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
                        } catch (e) {}
                    }
                    return ""; // markdown-it escapes for us
                }
            });

            // GitHub-style task list checkboxes (read-only).
            if (window.markdownitTaskLists) {
                md.use(window.markdownitTaskLists, { enabled: false, label: true });
            }

            // Route ```mermaid fences to a div Mermaid can pick up, instead of
            // syntax-highlighting them as code.
            var defaultFence = md.renderer.rules.fence.bind(md.renderer.rules);
            md.renderer.rules.fence = function (tokens, idx, options, env, self) {
                var token = tokens[idx];
                var info = token.info ? token.info.trim().split(/\\s+/)[0] : "";
                if (info === "mermaid") {
                    return '<pre class="mermaid">' + md.utils.escapeHtml(token.content) + "</pre>";
                }
                return defaultFence(tokens, idx, options, env, self);
            };

            document.getElementById("content").innerHTML = md.render(MD_SOURCE);

            // Notify the native host (if listening) that the page is fully
            // rendered. Quick Look uses this to wait for Mermaid before
            // snapshotting; the main app registers no handler, so this no-ops.
            function signalReady() {
                try {
                    window.webkit.messageHandlers["\(readyMessageName)"].postMessage(true);
                } catch (e) {}
            }

            var dark = window.matchMedia &&
                       window.matchMedia("(prefers-color-scheme: dark)").matches;

            if (window.mermaid) {
                window.mermaid.initialize({
                    startOnLoad: false,
                    securityLevel: "loose",
                    theme: dark ? "dark" : "default"
                });
                var nodes = document.querySelectorAll("pre.mermaid");
                if (nodes.length) {
                    window.mermaid.run({ nodes: nodes })
                        .then(signalReady)
                        .catch(function (err) { console.error("mermaid:", err); signalReady(); });
                } else {
                    signalReady();
                }
            } else {
                signalReady();
            }
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Escaping helpers

    /// JSON-encode a string into a JS string literal (safe for embedding).
    private static func jsonString(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\""
    }

    private static func escapeAttr(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
