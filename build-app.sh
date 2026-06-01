#!/bin/bash
# Build mdBuddy.app with an embedded Quick Look preview extension.
# Usage: ./build-app.sh [--debug] [--no-register]
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
REGISTER=1
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --no-register) REGISTER=0 ;;
    esac
done

APP_NAME="mdBuddy"
BUNDLE_ID="com.mdbuddy.app"
EXT_NAME="MarkdownQuickLook"
EXT_BUNDLE_NAME="MarkdownPreview"          # display name of the .appex
EXT_ID="${BUNDLE_ID}.quicklook"
APP="${APP_NAME}.app"
APPEX="${APP}/Contents/PlugIns/${EXT_BUNDLE_NAME}.appex"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"

# Vendored JS/CSS source. Copied as a loose Contents/Resources/vendor into both
# the app and the .appex so Renderer finds it via Bundle.main.resourceURL —
# avoiding SwiftPM's Bundle.module (whose accessor only knows a hardcoded .build
# path that is unreachable inside the sandboxed extension).
VENDOR_SRC="Sources/MarkdownKit/Resources/vendor"
[ -d "${VENDOR_SRC}" ] || { echo "ERROR: ${VENDOR_SRC} not found"; exit 1; }

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/PlugIns"

# --- Host app ---
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp -R "${VENDOR_SRC}" "${APP}/Contents/Resources/vendor"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.markdown</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Mermaid Diagram</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.mdbuddy.mermaid</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key><string>Markdown Document</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>md</string><string>markdown</string>
                    <string>mdown</string><string>mkd</string><string>mdx</string>
                </array>
                <key>public.mime-type</key>
                <array><string>text/markdown</string></array>
            </dict>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.mdbuddy.mermaid</string>
            <key>UTTypeDescription</key><string>Mermaid Diagram</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>mmd</string><string>mermaid</string></array>
                <key>public.mime-type</key>
                <array><string>text/vnd.mermaid</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# --- Quick Look extension (.appex) ---
echo "==> Assembling ${EXT_BUNDLE_NAME}.appex"
mkdir -p "${APPEX}/Contents/MacOS" "${APPEX}/Contents/Resources"
cp "${BIN_DIR}/${EXT_NAME}" "${APPEX}/Contents/MacOS/${EXT_NAME}"
# Loose vendor dir so Renderer finds it via Bundle.main.resourceURL inside the
# extension sandbox (no dependency on SwiftPM's Bundle.module / .build path).
cp -R "${VENDOR_SRC}" "${APPEX}/Contents/Resources/vendor"

# Use the SAME Info.plist that is embedded in the binary (__TEXT,__info_plist),
# so the bundle file and the embedded section never drift apart.
cp "Sources/${EXT_NAME}/Info.plist" "${APPEX}/Contents/Info.plist"

# --- Codesign (nested first), ad-hoc ---
# The extension MUST be sandboxed; without the app-sandbox entitlement,
# macOS's ExtensionFoundation aborts setting up the preview ("key cannot
# be nil") before it ever launches the extension.
echo "==> Codesigning (ad-hoc)"
EXT_ENTITLEMENTS="Sources/${EXT_NAME}/${EXT_NAME}.entitlements"
codesign --force --sign - --entitlements "${EXT_ENTITLEMENTS}" --timestamp=none "${APPEX}" \
    >/dev/null 2>&1 || echo "    (appex codesign skipped)"
codesign --force --sign - --timestamp=none "${APP}" >/dev/null 2>&1 \
    || echo "    (app codesign skipped)"

# --- Register with Launch Services + PlugInKit so Finder/Quick Look see it ---
# IMPORTANT: pkd reliably discovers the Quick Look extension only when the app
# lives in /Applications and has been launched once. We install there, register,
# launch, then explicitly enable the extension.
if [ "${REGISTER}" -eq 1 ]; then
    echo "==> Installing to /Applications and registering"
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    rm -rf "/Applications/${APP}"
    cp -R "${APP}" /Applications/
    # -R -trusted forces LaunchServices to absorb the exported UTI declarations
    # (e.g. com.mdbuddy.mermaid for .mmd); plain -f can leave .mmd as a dynamic
    # type, so Finder/Quick Look would not route it to this app.
    "${LSREGISTER}" -f -R -trusted "/Applications/${APP}" 2>/dev/null || true
    open "/Applications/${APP}" 2>/dev/null || true
    sleep 3
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    pluginkit -a "/Applications/${APP}/Contents/PlugIns/${EXT_BUNDLE_NAME}.appex" 2>/dev/null || true
    pluginkit -e use -i "${EXT_ID}" 2>/dev/null || true
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
    echo "    extension enabled in PlugInKit: $(pluginkit -m -i "${EXT_ID}" 2>/dev/null | head -1)"
fi

echo "==> Done."
echo "    Installed: /Applications/${APP}"
echo "    Quick Look test in Finder: select any .md file and press Space."
echo "    If Space still shows the system text preview, enable mdBuddy under"
echo "    System Settings > General > Login Items & Extensions > Quick Look,"
echo "    then run: qlmanage -r && qlmanage -r cache"
