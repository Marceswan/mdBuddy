// swift-tools-version:5.9
import PackageDescription
import Foundation

// Absolute path to the extension's Info.plist, computed from this manifest's
// location so the linker can embed it regardless of build CWD.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let extensionInfoPlist = packageRoot + "/Sources/MarkdownQuickLook/Info.plist"

let package = Package(
    name: "mdBuddy",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Shared rendering + vendored JS/CSS, linked by both the app and the
        // Quick Look extension so there's one Renderer and one copy of assets.
        .target(
            name: "MarkdownKit",
            resources: [
                .copy("Resources/vendor")
            ]
        ),
        // The main viewer app.
        .executableTarget(
            name: "mdBuddy",
            dependencies: ["MarkdownKit"]
        ),
        // Quick Look preview extension. Two linker requirements make a SwiftPM
        // executable behave like an Xcode-built .appex:
        //   1. Entry point is NSExtensionMain (not _main).
        //   2. The Info.plist is embedded as a __TEXT,__info_plist section so
        //      ExtensionFoundation can read the extension's identity. Without
        //      this the host crashes in makeExtensionContextAndXPCConnection
        //      with "key cannot be nil".
        // build-app.sh copies the same Info.plist into the .appex bundle.
        .executableTarget(
            name: "MarkdownQuickLook",
            dependencies: ["MarkdownKit"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", extensionInfoPlist
                ])
            ]
        )
    ]
)
