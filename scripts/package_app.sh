#!/bin/bash
# Create a local Release app + ZIP + SHA256 manifest. Never installs or launches.
# Usage: scripts/package_app.sh [--binary-dir <release binaries>] [--output <dir>]
#        [--sign-identity <Developer ID Application identity>]
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="dist"
BIN_DIR=""
SIGN_IDENTITY="-"
BUILD_NUMBER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --binary-dir) BIN_DIR="${2:?binary directory required}"; shift ;;
        --output) OUTPUT="${2:?output directory required}"; shift ;;
        --sign-identity) SIGN_IDENTITY="${2:?signing identity required}"; shift ;;
        --build-number) BUILD_NUMBER="${2:?build number required}"; shift ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
# Validate before building, creating directories or reading candidate binaries.
# Packaging never doubles as an installer, including through a symlink alias.
OUTPUT="$(python3 scripts/package_output.py check "$OUTPUT")"
VERSION="$(sed -n 's/^    public static let current = "\([0-9.]*\)"/\1/p' Sources/ContextOSCore/Model/ContextOSVersion.swift)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid build number" >&2; exit 1; }
if [ -z "$BIN_DIR" ]; then
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi
for binary in ContextOSApp contextos contextos-mcp; do
    [ -x "$BIN_DIR/$binary" ] || { echo "Missing Release binary: $binary" >&2; exit 1; }
done
[ "$("$BIN_DIR/contextos" --version)" = "$VERSION" ] || { echo "CLI version mismatch" >&2; exit 1; }
[ "$("$BIN_DIR/contextos-mcp" --version)" = "$VERSION" ] || { echo "MCP version mismatch" >&2; exit 1; }
mkdir -p "$OUTPUT"
LOCK_DIR="$OUTPUT/.contextos-package.lock"
mkdir "$LOCK_DIR" || { echo "Another package operation owns this output" >&2; exit 1; }
STAGE_DIR=""
cleanup() {
    [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
    rmdir "$LOCK_DIR"
}
trap cleanup EXIT
STAGE_DIR="$(mktemp -d "$OUTPUT/.package-XXXXXX")"
APP="$STAGE_DIR/ContextOS.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ContextOSApp" "$APP/Contents/MacOS/ContextOSApp"
cp "$BIN_DIR/contextos" "$BIN_DIR/contextos-mcp" "$APP/Contents/Resources/"
# Keep development/debug metadata out of the shipped executables. Strip before
# signing; executable code and the build-directory originals are unchanged.
for binary in "$APP/Contents/MacOS/ContextOSApp" "$APP/Contents/Resources/contextos" "$APP/Contents/Resources/contextos-mcp"; do
    /usr/bin/strip -S "$binary"
done
[ ! -f AppIcon.icns ] || cp AppIcon.icns "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md docs/PRIVACY.md docs/INSTALL.md "$APP/Contents/Resources/"
cp -R ThirdPartyLicenses "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ContextOS</string>
<key>CFBundleDisplayName</key><string>ContextOS</string>
<key>CFBundleIdentifier</key><string>com.contextos.app</string>
<key>CFBundleExecutable</key><string>ContextOSApp</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>ContextOSURLScheme</key><string>contextos</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.contextos.app.usage</string><key>CFBundleURLSchemes</key><array><string>contextos</string></array></dict></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST
# Sign nested executables explicitly before the outer bundle. '-' is local
# ad-hoc signing, needs no account/certificate and is not distribution signing.
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_ARGS+=(--options runtime --timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/contextos"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/contextos-mcp"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/verify_bundle.py "$APP"
ARCH="$(lipo -archs "$BIN_DIR/ContextOSApp" | tr ' ' '-')"
ARCHIVE="ContextOS-$VERSION-macos-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE_DIR/$ARCHIVE"
SIGNING="ad-hoc-local-only"
SIGN_DETAILS="$(codesign --display --verbose=2 "$APP" 2>&1)"
case "$SIGN_DETAILS" in
    *"Authority=Developer ID Application:"*) SIGNING="developer-id-not-yet-notarized" ;;
    *"Signature=adhoc"*) SIGNING="ad-hoc-local-only" ;;
    *) SIGNING="development-local-only" ;;
esac
python3 - "$VERSION" "$ARCH" "$SIGNING" "$STAGE_DIR/$ARCHIVE" "$BUILD_NUMBER" <<'PY'
import hashlib,json,pathlib,sys
version,arch,signing,archive,build=sys.argv[1:]
p=pathlib.Path(archive)
digest=hashlib.sha256(p.read_bytes()).hexdigest()
p.with_suffix('.sha256').write_text(digest+'  '+p.name+'\n')
p.with_suffix('.json').write_text(json.dumps({'version':version,'build':build,'architecture':arch,'signing':signing,'notarized':False,'archive':p.name,'sha256':digest},indent=2)+'\n')
PY
# Publish only new artifacts. A failed move restores all staged files; the EXIT
# trap only removes this invocation's candidate, never a previous output/app.
python3 scripts/package_output.py publish "$OUTPUT" "$STAGE_DIR" \
    "$ARCHIVE" "${ARCHIVE%.zip}.sha256" "${ARCHIVE%.zip}.json" ContextOS.app
echo "Created $OUTPUT/$ARCHIVE ($SIGNING; notarization still required). No installation or launch performed."
