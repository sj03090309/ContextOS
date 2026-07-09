#!/bin/bash
# Package ContextOS into a double-clickable macOS .app bundle.
# Usage: scripts/build_app.sh [output_dir]   (default: ./dist)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/ContextOS.app"

echo "▶︎ Building release binaries…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▶︎ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/ContextOSApp" "$APP/Contents/MacOS/ContextOSApp"
# Bundle the CLI + MCP server so the app can point Claude Code at them.
cp "$BIN_DIR/contextos" "$APP/Contents/Resources/contextos"
cp "$BIN_DIR/contextos-mcp" "$APP/Contents/Resources/contextos-mcp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ContextOS</string>
    <key>CFBundleDisplayName</key>     <string>ContextOS</string>
    <key>CFBundleIdentifier</key>      <string>com.contextos.app</string>
    <key>CFBundleExecutable</key>      <string>ContextOSApp</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "▶︎ Ad-hoc code signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built $APP"
echo "  더블클릭하거나 /Applications 로 드래그하세요."
