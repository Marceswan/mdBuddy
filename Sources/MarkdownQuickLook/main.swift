import Foundation

// App extensions enter through NSExtensionMain, which we set as the Mach-O
// entry point via the linker flag `-e _NSExtensionMain` (see Package.swift).
// This top-level main is therefore never executed; the reference below simply
// guarantees the principal class is linked into the binary (and not dead
// stripped), so NSExtensionMain can instantiate it by name from Info.plist.
_ = PreviewViewController.self
