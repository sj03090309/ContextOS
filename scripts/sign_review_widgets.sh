#!/bin/bash
# Explicitly approved, local development signing for the isolated review app.
# No certificate creation, account login, installation, notarization or upload.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${1:?Usage: sign_review_widgets.sh <existing identity SHA1> <new output directory>}"
OUTPUT="${2:?new output directory required}"
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo 'Expected an existing signing identity SHA1'; exit 2; }
[ ! -e "$OUTPUT" ] || { echo 'Refusing to overwrite output'; exit 2; }
bash scripts/package_widgets.sh --review --output "$OUTPUT"
APP="$OUTPUT/ContextOS Widget Review.app"
GROUP="Y56BH9PULD.com.contextos.review.usage"
python3 - "$APP" "$GROUP" <<'PY'
import pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]); group=sys.argv[2]
for relative in ('Contents/Info.plist','Contents/PlugIns/ContextOSWidgets.appex/Contents/Info.plist'):
    p=app/relative; info=plistlib.loads(p.read_bytes())
    assert info['CFBundleIdentifier'] in ('com.contextos.review','com.contextos.review.widgets')
    info['ContextOSAppGroup']=group
    p.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign "$IDENTITY" --entitlements NativeWidgets/ReviewWidget.entitlements "$APP/Contents/PlugIns/ContextOSWidgets.appex"
codesign --force --sign "$IDENTITY" --entitlements NativeWidgets/ReviewHost.entitlements "$APP"
codesign --verify --deep --strict "$APP"
python3 - "$APP" <<'PY'
import pathlib, subprocess, sys
app=pathlib.Path(sys.argv[1])
for p in (app, app/'Contents/PlugIns/ContextOSWidgets.appex'):
    r=subprocess.run(['codesign','-dv',str(p)],capture_output=True,text=True,check=True)
    assert 'TeamIdentifier=Y56BH9PULD' in r.stderr, 'Signed team differs from approved team'
print('Approved review team and group verified. Installation has not been performed.')
PY
