import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: DocumentModel
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if model.currentURL != nil {
                MarkdownWebView(model: model)
            } else {
                EmptyState()
            }

            if let err = model.loadError {
                VStack {
                    Spacer()
                    Text(err)
                        .font(.callout)
                        .padding(10)
                        .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .padding()
                }
            }

            if isTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { model.open(url) }
        }
        return true
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("mdBuddy")
                .font(.title2).bold()
            Text("Drop a Markdown file here, or press \u{2318}O to open one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
