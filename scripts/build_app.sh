#!/bin/bash
# Package ContextOS into a macOS .app bundle and install it over the existing one.
#
# There must only ever be ONE ContextOS.app on the machine. The bundle id is
# fixed (com.contextos.app), so a second copy at a different path is treated by
# macOS as a separate app and puts a SECOND mascot in the menu bar. That is why
# this script installs rather than leaving a loose copy in dist/ for you to drag
# somewhere: a build artifact you can double-click is a duplicate waiting to
# happen.
#
# Usage:
#   scripts/build_app.sh                # build, install over the existing app, relaunch
#   scripts/build_app.sh --to <path>    # install to an explicit path
#   scripts/build_app.sh --no-install   # leave the bundle in dist/ and stop (CI)
set -euo pipefail

cd "$(dirname "$0")/.."

INSTALL=1
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-install) INSTALL=0 ;;
        --to) TARGET="${2:?--to 에 경로가 필요합니다}"; shift ;;
        # Print the header block itself rather than a copy of it, and take every
        # comment line after the shebang so the two can't drift apart.
        -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
    shift
done

# The menu-bar app only. This must never match
# .../Contents/Resources/contextos-mcp — that is the MCP server an editor may be
# talking to right now, and killing it drops the connection mid-session.
APP_PROCESS="ContextOS.app/Contents/MacOS/ContextOSApp"

# Where is ContextOS already installed? In order of authority:
#   1. a bundle running right now — that is the one the user actually sees
#   2. the bundle an editor launches the MCP server from
#   3. the usual places
find_install() {
    local running mcp path
    running="$(pgrep -fl "$APP_PROCESS" 2>/dev/null | head -1 | sed 's/^[0-9]* //' || true)"
    if [ -n "$running" ]; then
        echo "${running%/Contents/MacOS/ContextOSApp}"; return
    fi
    if [ -f "$HOME/.claude.json" ]; then
        mcp="$(grep -o "/[^\"]*/ContextOS\.app/Contents/Resources/contextos-mcp" \
               "$HOME/.claude.json" 2>/dev/null | head -1 || true)"
        if [ -n "$mcp" ]; then
            echo "${mcp%/Contents/Resources/contextos-mcp}"; return
        fi
    fi
    for path in "/Applications/ContextOS.app" "$HOME/Applications/ContextOS.app" \
                "$HOME/Desktop/ContextOS.app"; do
        [ -d "$path" ] && { echo "$path"; return; }
    done
}

echo "▶︎ Building release binaries…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# Assemble into a staging dir so a half-built bundle can never replace a working
# install, and so no second launchable copy is left lying around on success.
STAGE_DIR="dist/.stage"
STAGE="$STAGE_DIR/ContextOS.app"
echo "▶︎ Assembling bundle…"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN_DIR/ContextOSApp" "$STAGE/Contents/MacOS/ContextOSApp"
# Bundle the CLI + MCP server so the app can point AI agents at them.
cp "$BIN_DIR/contextos" "$STAGE/Contents/Resources/contextos"
cp "$BIN_DIR/contextos-mcp" "$STAGE/Contents/Resources/contextos-mcp"
# App icon (regenerate with: swift scripts/make_icon.swift)
[ -f AppIcon.icns ] && cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ContextOS</string>
    <key>CFBundleDisplayName</key>     <string>ContextOS</string>
    <key>CFBundleIdentifier</key>      <string>com.contextos.app</string>
    <key>CFBundleExecutable</key>      <string>ContextOSApp</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
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
codesign --force --deep --sign - "$STAGE" >/dev/null 2>&1 || echo "  (codesign skipped)"

if [ "$INSTALL" = 0 ]; then
    rm -rf dist/ContextOS.app
    mv "$STAGE" dist/ContextOS.app
    rm -rf "$STAGE_DIR"
    echo "✓ dist/ContextOS.app (설치 안 함)"
    echo "  ⚠️  이건 빌드 산출물입니다. 실행하면 설치된 앱과 별개로 떠서"
    echo "      메뉴바 아이콘이 2개가 됩니다. 설치하려면 --no-install 없이 다시 실행하세요."
    exit 0
fi

[ -n "$TARGET" ] || TARGET="$(find_install)"
[ -n "$TARGET" ] || TARGET="/Applications/ContextOS.app"

# Stop the old app before swapping it — but only the app.
WAS_RUNNING=0
if pgrep -f "$APP_PROCESS" >/dev/null 2>&1; then
    WAS_RUNNING=1
    echo "▶︎ 실행 중인 앱 종료…"
    pkill -f "$APP_PROCESS" || true
    sleep 1
fi

echo "▶︎ Installing → $TARGET"
# Safe even while this bundle's contextos-mcp is running: unlink leaves the live
# process on its old inode, and it picks up the new binary when it next starts.
rm -rf "$TARGET"
mkdir -p "$(dirname "$TARGET")"
# ditto, not cp: it is the macOS-native copy and preserves the code signature.
ditto "$STAGE" "$TARGET"
rm -rf "$STAGE_DIR"

# A leftover staging copy is a second launchable bundle — the exact cause of the
# duplicate menu-bar icon. Never leave one behind.
if [ -d "dist/ContextOS.app" ] && [ "$(cd dist && pwd)/ContextOS.app" != "$TARGET" ]; then
    rm -rf dist/ContextOS.app
    echo "  (오래된 dist/ContextOS.app 복사본 제거 — 아이콘 중복 방지)"
fi

# Any other copy on disk would show up as its own menu-bar icon.
for other in "/Applications/ContextOS.app" "$HOME/Applications/ContextOS.app" \
             "$HOME/Desktop/ContextOS.app"; do
    if [ -d "$other" ] && [ "$other" != "$TARGET" ]; then
        echo "  ⚠️  다른 복사본이 있습니다: $other"
        echo "      실행하면 메뉴바 아이콘이 2개가 됩니다. 지우세요: rm -rf \"$other\""
    fi
done

if [ "$WAS_RUNNING" = 1 ]; then
    echo "▶︎ 재실행…"
    open "$TARGET"
fi

echo "✓ Installed $TARGET"
[ "$WAS_RUNNING" = 1 ] || echo "  실행: open \"$TARGET\""
