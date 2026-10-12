#!/bin/bash
# Build an isolated candidate; never install, launch, register capabilities or fetch credentials.
# Usage: scripts/package_widgets.sh [--binary-dir <dir>] [--review] [--output <dir>]
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="dist/widgets"
BIN_DIR=""
REVIEW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --binary-dir) BIN_DIR="${2:?binary directory required}"; shift ;;
        --output) OUTPUT="${2:?output directory required}"; shift ;;
        --review) REVIEW=1 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
ID="com.contextos.app"; SCHEME="contextos"; NAME="ContextOS"
if [ "$REVIEW" -eq 1 ]; then ID="com.contextos.review"; SCHEME="contextos-review"; NAME="ContextOS Widget Review"; fi
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
STAGE="$(mktemp -d "$OUTPUT/.widget-package-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ARGS=(--output "$STAGE/base")
[ -z "$BIN_DIR" ] || ARGS+=(--binary-dir "$BIN_DIR")
bash scripts/package_app.sh "${ARGS[@]}"
xcodebuild -project NativeWidgets/ContextOSWidgets.xcodeproj -target ContextOSWidgets \
    -configuration Release SYMROOT="$PWD/.build/widgets" OBJROOT="$PWD/.build/widget-intermediates" \
    MODULE_CACHE_DIR="${TMPDIR:-/tmp}/contextos-widget-modules" \
    SHARED_PRECOMPS_DIR="${TMPDIR:-/tmp}/contextos-widget-precomps" \
    PRODUCT_BUNDLE_IDENTIFIER="$ID.widgets" CONTEXTOS_URL_SCHEME="$SCHEME" \
    CODE_SIGNING_ALLOWED=NO build
APP="$STAGE/$NAME.app"
mv "$STAGE/base/ContextOS.app" "$APP"
mkdir -p "$APP/Contents/PlugIns"
cp -R .build/widgets/Release/ContextOSWidgets.appex "$APP/Contents/PlugIns/"
python3 - "$APP" "$ID" "$SCHEME" "$NAME" <<'PY'
import pathlib, plistlib, sys
app, bid, scheme, name=sys.argv[1:]
p=pathlib.Path(app)/'Contents/Info.plist'
info=plistlib.loads(p.read_bytes())
info.update(CFBundleIdentifier=bid, CFBundleDisplayName=name, CFBundleName=name,
            ContextOSURLScheme=scheme,
            CFBundleURLTypes=[dict(CFBundleURLName=bid+'.usage', CFBundleURLSchemes=[scheme])])
p.write_bytes(plistlib.dumps(info))
e=pathlib.Path(app)/'Contents/PlugIns/ContextOSWidgets.appex/Contents/Info.plist'
ext=plistlib.loads(e.read_bytes())
for key in ('CFBundleShortVersionString','CFBundleVersion'): ext[key]=info[key]
e.write_bytes(plistlib.dumps(ext))
assert ext['CFBundleIdentifier'].startswith(bid+'.')
assert ext['NSExtension']['NSExtensionPointIdentifier']=='com.apple.widgetkit-extension'
assert not ext.get('ContextOSAppGroup'), 'This local-only packaging command must not enable an unapproved App Group'
PY
codesign --force --sign - "$APP/Contents/PlugIns/ContextOSWidgets.appex"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
[ ! -e "$OUTPUT/$NAME.app" ] || { echo "Refusing to overwrite an existing candidate; choose a new output directory" >&2; exit 2; }
mv "$APP" "$OUTPUT/$NAME.app"
echo "Created $OUTPUT/$NAME.app (ad-hoc local candidate). App Group is unconfigured. No installation or launch performed."
