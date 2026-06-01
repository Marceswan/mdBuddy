# mdBuddy

A super-lightweight native macOS app for **opening and reading rendered Markdown** — with **Mermaid diagrams rendered inline**.

No Electron. A single Swift binary + a WKWebView, with markdown-it, highlight.js, and Mermaid bundled locally (zero network access at runtime).

## Features

- GitHub-flavored Markdown rendering (tables, blockquotes, task lists, etc.)
- Syntax highlighting for fenced code blocks (highlight.js)
- **Inline Mermaid diagrams** (` ```mermaid ` fences render as SVG)
- Light / dark mode follows the system appearance automatically
- Auto-reload: edit the file in any editor and the view refreshes, keeping your scroll position
- Open via drag-and-drop, `Cmd+O`, the command line, or Finder's "Open With"
- Relative image paths resolve against the Markdown file's folder
- **Quick Look preview extension**: select a `.md` file in Finder and press Space
  to see it rendered (with Mermaid), using the same engine as the app

## Run it (dev)

```bash
swift run                 # opens the empty window
swift run mdBuddy sample.md   # opens a file directly
```

## Build a double-clickable app

```bash
./build-app.sh            # -> mdBuddy.app  (release build, ad-hoc signed)
open mdBuddy.app                       # launch
open -a "$PWD/mdBuddy.app" sample.md   # open a file
cp -R mdBuddy.app /Applications/       # install
```

To make mdBuddy the default Markdown viewer: right-click a `.md` file in Finder >
Get Info > "Open with" > choose mdBuddy > "Change All".

## Quick Look (Space bar)

`mdBuddy.app` embeds a Quick Look preview extension
(`Contents/PlugIns/MarkdownPreview.appex`) that renders `.md` files with the
same `Renderer` the app uses. `build-app.sh` installs the app to
`/Applications`, registers it, and enables the extension. Then:

- Select any `.md` file in Finder and press **Space**.

Notes / caveats:

- The extension **must be sandboxed** (`MarkdownQuickLook.entitlements`).
  Without the `app-sandbox` entitlement, macOS aborts setting up the preview
  with "key cannot be nil" before the extension ever runs.
- The SwiftPM binary is turned into a real `.appex` by two linker tricks in
  `Package.swift`: entry point `-e _NSExtensionMain`, and the `Info.plist`
  embedded as a `__TEXT,__info_plist` section (Xcode does this automatically).
- macOS ships a built-in plain-text Quick Look preview. mdBuddy claims the more
  specific `net.daringfireball.markdown` type, so Finder should prefer it. If
  Space still shows plain text, enable mdBuddy under **System Settings >
  General > Login Items & Extensions > Quick Look**, then run
  `qlmanage -r && qlmanage -r cache`.
- `qlmanage -p` (the CLI tool) is unreliable for view-based preview extensions
  and may show the system previewer instead; trust Finder's Space bar.

## How it works

1. `DocumentModel` tracks the open file and polls its mtime/size to detect edits.
2. `Renderer` builds one self-contained HTML document, inlining the vendored
   JS/CSS and embedding the Markdown as a JSON string.
3. `MarkdownWebView` writes that HTML to a temp file and loads it into a
   `WKWebView`, granting read access to the Markdown's directory so relative
   images load. markdown-it renders the Markdown, highlight.js colors code, and
   Mermaid turns ` ```mermaid ` fences into SVG — all client-side.

## Vendored libraries

`Sources/mdBuddy/Resources/vendor/` (all local, no CDN at runtime):

| File | Library |
|------|---------|
| `markdown-it.min.js` | markdown-it 14.1.0 |
| `markdown-it-task-lists.min.js` | task-list checkboxes (read-only) |
| `highlight.min.js` + `hljs-github*.css` | highlight.js 11.10.0 |
| `mermaid.min.js` | Mermaid 11.4.1 |
| `github-markdown.css` | github-markdown-css 5.8.1 |

## Notes

- Markdown is rendered with `html: true` (inline HTML in your files is honored),
  the same model as VS Code's preview. The view is a local-only sandboxed
  WKWebView with no network origin.
- Requires macOS 13+.
