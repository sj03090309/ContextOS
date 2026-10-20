#!/bin/bash
# Isolated UI candidate: unique bundle ID, no extension, no App Group, no install.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:?new output directory required}"
[ ! -e "$OUTPUT" ] || { echo 'Refusing to overwrite candidate'; exit 2; }
swift build --jobs 2 --product ContextOSApp
APP="$OUTPUT/ContextOS Time Candidate.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/ContextOSApp "$APP/Contents/MacOS/ContextOSApp"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1])
info=dict(CFBundleIdentifier='com.contextos.timecandidate',CFBundleName='ContextOS Time Candidate',
          CFBundleDisplayName='ContextOS Time Candidate',CFBundleExecutable='ContextOSApp',
          CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='0.1',
          LSMinimumSystemVersion='14.0',NSHighResolutionCapable=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Created isolated candidate; no App Group or installation performed."
