import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MdBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: appDelegate.model)
                .onAppear { appDelegate.flushPendingOpen() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") { appDelegate.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") { appDelegate.model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(appDelegate.model.currentURL == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DocumentModel()
    private var pendingURL: URL?
    private var didAppear = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Support `mdBuddy path/to/file.md` from the command line / `swift run`.
        let args = CommandLine.arguments.dropFirst()
        if let path = args.first(where: { !$0.hasPrefix("-") }) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                pendingURL = url
            }
        }
    }

    // Finder "Open" / "Open With" / drag-onto-icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if didAppear {
            model.open(url)
        } else {
            pendingURL = url
        }
    }

    /// Open whatever was requested before the window existed.
    func flushPendingOpen() {
        didAppear = true
        if let url = pendingURL {
            pendingURL = nil
            model.open(url)
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.markdownTypes
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static var markdownTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        for id in ["net.daringfireball.markdown", "public.markdown", "com.mdbuddy.mermaid"] {
            if let t = UTType(id) { types.append(t) }
        }
        for ext in ["md", "markdown", "mdown", "mkd", "mdx", "mmd", "mermaid"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}
