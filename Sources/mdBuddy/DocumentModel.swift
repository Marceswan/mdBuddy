import Foundation
import Combine

/// Holds the currently-open markdown file and watches it for changes on disk
/// so the rendered view auto-reloads while you read.
final class DocumentModel: ObservableObject {
    /// The markdown file currently displayed (nil = empty state).
    @Published private(set) var currentURL: URL?
    /// Bumps every time the file's contents change on disk. The web view
    /// watches this to re-render in place (preserving scroll position).
    @Published private(set) var version: Int = 0
    /// Last read error, surfaced in the UI.
    @Published private(set) var loadError: String?

    private var watchTimer: Timer?
    private var lastSignature: FileSignature?

    /// Open a new file. Resets scroll to the top on the next render.
    func open(_ url: URL) {
        stopWatching()
        let resolved = url.resolvingSymlinksInPath()
        currentURL = resolved
        loadError = nil
        lastSignature = FileSignature(for: resolved)
        version += 1
        startWatching()
    }

    /// Read the current file's text. Returns nil (and sets loadError) on failure.
    func readMarkdown() -> String? {
        guard let url = currentURL else { return nil }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            loadError = nil
            return text
        } catch {
            // Fall back to a lenient read for non-UTF8 files.
            if let data = try? Data(contentsOf: url) {
                loadError = nil
                return String(decoding: data, as: UTF8.self)
            }
            loadError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// Force a re-render of the current file.
    func reload() {
        guard currentURL != nil else { return }
        version += 1
    }

    // MARK: - File watching (poll mtime+size; robust against atomic-save editors)

    private struct FileSignature: Equatable {
        let size: Int
        let mtime: TimeInterval
        init?(for url: URL) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  let date = attrs[.modificationDate] as? Date else { return nil }
            self.size = size
            self.mtime = date.timeIntervalSince1970
        }
    }

    private func startWatching() {
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func checkForChanges() {
        guard let url = currentURL else { return }
        let sig = FileSignature(for: url)
        if sig != lastSignature {
            lastSignature = sig
            version += 1
        }
    }
}
