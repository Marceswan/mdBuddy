# learnings

Project-specific gotchas already debugged once, so the next session does not
rediscover them.

## 2026-05-29 — quicklook-appex-from-swiftpm

**Symptom:** A hand-assembled Quick Look preview extension (`.appex` built from
a SwiftPM executable target, ad-hoc signed, embedded in `mdBuddy.app/Contents/
PlugIns/`) made the host crash:
`*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil` in
`-[EXConcreteExtension makeExtensionContextAndXPCConnectionForRequest:error:]`
(qlmanage / quicklookd, macOS 26.5, ExtensionFoundation v97).

**Root cause:** Two things Xcode does for app-extension targets that SwiftPM
does not:
1. The extension binary needs the **Info.plist embedded** as a
   `__TEXT,__info_plist` Mach-O section (not just the bundle Info.plist file),
   or ExtensionFoundation reads a nil identity.
2. The extension **must be sandboxed** — the `com.apple.security.app-sandbox`
   entitlement. Without it the host aborts with the nil-key error *before*
   launching the extension. This was the actual fix for the crash.

**Fix / prevention:**
- Entry point: link the extension with `-e _NSExtensionMain` (it has no `_main`;
  provide a dummy `main.swift` that references the principal class so it is not
  dead-stripped).
- Embed the plist:
  `-sectcreate __TEXT __info_plist <abs path to Info.plist>` (compute the abs
  path in `Package.swift` from `#filePath`; `exclude` the plist from the target
  so SwiftPM does not treat it as a source).
- Ad-hoc codesign the `.appex` WITH an entitlements file containing
  `com.apple.security.app-sandbox` + `com.apple.security.files.user-selected.read-only`.
- Principal class: `@objc(PreviewViewController)` and
  `NSExtensionPrincipalClass = PreviewViewController` (no module prefix).
- Registration only sticks when the app is in **/Applications**, launched once,
  then `pluginkit -a <appex>` and `pluginkit -e use -i <ext bundle id>`. Confirm
  with `pluginkit -m -i <id>` (a leading `+` means enabled).

**Avoid:**
- `qlmanage -p`/`-o` are unreliable for **view-based** `QLPreviewingController`
  extensions: `-o` reports "did not produce any preview" (it only handles
  data-based previews) and `-p` often launches Apple's built-in
  `QLPreviewGenerationExtension` instead. Do NOT treat qlmanage output as the
  source of truth — verify with Finder Space bar.
- Launch Services knowing the plugin (`lsregister -dump` shows it) is NOT
  sufficient; **pkd** must also have it (`pluginkit -m`). They are separate.
- Embedding the plist alone did not fix the crash — the sandbox entitlement did.

**References:** `Package.swift` (linker flags), `build-app.sh` (sign + register),
`Sources/MarkdownQuickLook/{Info.plist,MarkdownQuickLook.entitlements,PreviewViewController.swift}`.

## 2026-06-01 — quicklook-blank-needs-network-client-entitlement

**Symptom:** Quick Look preview came up blank. The extension ran fine
(`preparePreviewOfFile` logged the file + char count) but
`webView(_:didFinish:)` NEVER fired even after 15s; only the 3s fallback timer
completed the (blank) preview. WebKit log showed:
`WebContent[0] Application does not have permission to communicate with network
resources. rc=1 : errno=34`, then `WebProcessProxy::processDidTerminateOrFailedToLaunch:
reason=Crash` and `GPUProcessProxy::gpuProcessExited: reason=Crash`.

**Root cause:** A sandboxed app extension hosting a `WKWebView` must hold the
`com.apple.security.network.client` entitlement, or WebKit's WebContent/GPU
helper XPC processes fail to launch -- **even for fully local, inlined content
with `baseURL: nil` and zero network use**. The entitlement file had it
explicitly set to `<false/>`. With the helpers dead, the load neither finishes
nor fails; the view stays blank.

**Fix / prevention:** Set `com.apple.security.network.client` to `<true/>` in
`Sources/MarkdownQuickLook/MarkdownQuickLook.entitlements`, rebuild/re-sign.
Confirm via the extension's own os_log: `page reported ready` + `navigation
didFinish` appear, no WebContent crash. Diagnose with
`log stream --predicate 'process == "MarkdownQuickLook"'` filtered for
`WebContent`/`permission to communicate`.

**Avoid:** Do NOT chase the inlined HTML/JS as the culprit -- the same
`Renderer` HTML renders perfectly in a normal browser. The tell is that
`didFinish` never fires AND a WebContent crash appears; that is process launch,
not page content. `baseURL: nil` was already correct and is unrelated.

**References:** `Sources/MarkdownQuickLook/MarkdownQuickLook.entitlements:7`,
`PreviewViewController.swift` (loadHTMLString + ready/didFinish logging).

## 2026-06-01 — app-blank-loadfileurl-main-resource-outside-readaccess

**Symptom:** Main app window blank when opening a `.md` file. WebKit log under
`process == "mdBuddy"`: `Ignoring request to load this main resource because it
is outside the sandbox`.

**Root cause:** `MarkdownWebView.Coordinator.render` writes the rendered HTML to
the system temp dir (`FileManager.default.temporaryDirectory/mdBuddy/render.html`)
then calls `loadFileURL(tempHTMLURL, allowingReadAccessTo: baseDir)` where
`baseDir` is the markdown file's folder. WKWebView refuses to load a **main
resource** that sits OUTSIDE the `allowingReadAccessTo` subtree. The temp file
is not under `baseDir`, so the load is rejected and the window stays blank.
(`allowingReadAccessTo` governs the main document too, not just subresources.)

**Fix / prevention:** Grant read access to a root that contains both the temp
HTML and the markdown's folder. The app is not sandboxed, so
`loadFileURL(tempHTMLURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))`
fixes it and keeps relative-image loading (images still resolve from `baseDir`
via `<base href>`). Verify: 0 `outside the sandbox` lines in the mdBuddy log
after opening a file.

**Avoid:** A quick `loadFileURL` test where BOTH the temp file and the
read-access dir live under `/var/folders/.../T` will MISLEADINGLY succeed (WebKit
permits the shared temp tree). Reproduce faithfully: temp file in the real
system temp, read-access pointing at a folder under `~`. Writing the HTML into
`baseDir` instead also works but pollutes the user's folder and breaks on
read-only dirs.

**References:** `Sources/mdBuddy/MarkdownWebView.swift` (`render`, the
`loadFileURL` call).

## 2026-06-01 — mmd-files-need-exported-uti-and-lsregister-R-trusted

**Symptom:** Added `.mmd` (raw Mermaid) support. The Quick Look extension
rendered `.mmd` when invoked via `qlmanage -p <path>`, but `mdls` reported the
file's type as a dynamic UTI (`dyn.ah62d4rv4ge8045pe`, conforming only to
`public.data`) instead of `com.mdbuddy.mermaid` -- so Finder Space bar / "Open
With" would not reliably route `.mmd` to the app.

**Root cause:** A new file extension with no system UTI needs an
`UTExportedTypeDeclarations` entry in the app Info.plist, AND LaunchServices has
to absorb it. `build-app.sh` registered with `lsregister -f` only, which left
`.mmd` as a dynamic type.

**Fix / prevention:** Declare `com.mdbuddy.mermaid` (conforms to
`public.plain-text`, extensions `mmd`/`mermaid`) under
`UTExportedTypeDeclarations` in the app Info.plist; reference it from the app's
`CFBundleDocumentTypes` and the extension's `QLSupportedContentTypes`. Register
with `lsregister -f -R -trusted /Applications/mdBuddy.app`. Confirm with
`mdls -name kMDItemContentType <fresh copy>` -> `com.mdbuddy.mermaid` and
`lsregister -dump | grep com.mdbuddy.mermaid` showing
`plugin Identifiers: com.mdbuddy.app.quicklook`.

**Avoid:** `mdls` caches per inode -- test a freshly `cp`'d file, not the one
that was stat'd before re-registering, or you will see the stale dynamic type
and think the fix failed.

**References:** `build-app.sh` (Info.plist heredoc + `lsregister` line),
`Sources/MarkdownQuickLook/Info.plist` (QLSupportedContentTypes),
`Sources/MarkdownKit/Renderer.swift` (`html(forFileAt:content:)`,
`htmlForMermaidDiagram`).

## 2026-06-01 — untrusted-markdown-xss-hardening (do not regress)

**Symptom:** Security review flagged the renderer: `html: true` markdown-it with
no sanitizer, Mermaid `securityLevel: "loose"`, and (newly introduced)
`loadFileURL(..., allowingReadAccessTo: URL(fileURLWithPath: "/"))`. Opening a
hostile `.md` could run injected JS and read/exfiltrate arbitrary local files.
Also discovered: a `.md` containing `</script>` broke rendering outright,
because the markdown is embedded into a `<script>` block and `JSONEncoder` does
NOT escape `<` -> the HTML parser closed our script tag early (script-context
breakout = the XSS mechanism).

**Root cause:** WKWebView renders attacker-controlled HTML/JS with broad file
access and no CSP. `JSONEncoder` output is not safe to drop inside `<script>`.

**Fix / prevention (all four layers are load-bearing -- keep them):**
1. `Renderer.jsonString` escapes `<` `>` `&` (and U+2028/U+2029) as `\uXXXX`
   so embedded markdown can never break out of the `<script>` tag.
2. CSP `<meta>` per render: `script-src 'nonce-<uuid>'` (our 5 script tags carry
   the nonce; attacker `<script>` does not -> blocked) + `connect-src 'none'`
   (no fetch/XHR -> no file exfiltration even if script ran) + `default-src
   'none'`. `style-src 'unsafe-inline'` is REQUIRED (inlined CSS + Mermaid styles).
3. Mermaid `securityLevel: "strict"` (was "loose").
4. App grants `allowingReadAccessTo: baseDir` (NOT `/`) by writing
   `.mdBuddy-preview.html` INTO the markdown's folder, scoping file reach to the
   opened directory. (Quick Look already uses `baseURL: nil`, fully inlined.)

Verified in real WebKit: markdown + Mermaid render (svg present), and an
injected `</script>`/`<script>`/`onerror` probe does NOT execute.

**Avoid:** Do NOT revert step 4 to `allowingReadAccessTo: "/"` -- that was the
CRITICAL finding. Do NOT set Mermaid back to "loose". Do NOT add `'unsafe-eval'`
or `'unsafe-inline'` to `script-src` (defeats the nonce). Mermaid 11.4.1 renders
fine under strict CSP with no `eval` -- confirmed.

**References:** `Sources/MarkdownKit/Renderer.swift` (CSP/nonce/jsonString/
securityLevel), `Sources/mdBuddy/MarkdownWebView.swift` (`render`,
`removeRenderFile`).
