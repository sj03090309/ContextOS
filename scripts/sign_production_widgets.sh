#!/bin/bash
# User-approved local production group. No new identity, account operation,
# profile generation, installation, notarization or upload.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${1:?existing identity SHA1 required}"
OUTPUT="${2:?new output directory required}"
BIN_DIR="${3:?built Release binary directory required}"
BUILD_NUMBER="${4:?explicit build number required}"
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] || exit 2
[ ! -e "$OUTPUT" ] || { echo 'Refusing to overwrite output'; exit 2; }
bash scripts/package_widgets.sh --binary-dir "$BIN_DIR" --build-number "$BUILD_NUMBER" --output "$OUTPUT"
APP="$OUTPUT/ContextOS.app"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1])
for rel,bid in [('Contents/Info.plist','com.contextos.app'),('Contents/PlugIns/ContextOSWidgets.appex/Contents/Info.plist','com.contextos.app.widgets')]:
 p=app/rel;d=plistlib.loads(p.read_bytes());assert d['CFBundleIdentifier']==bid
 d['ContextOSAppGroup']='Y56BH9PULD.com.contextos.usage';p.write_bytes(plistlib.dumps(d))
PY
for BINARY in contextos contextos-mcp; do codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/$BINARY"; done
codesign --force --sign "$IDENTITY" --entitlements NativeWidgets/ProductionWidget.entitlements "$APP/Contents/PlugIns/ContextOSWidgets.appex"
codesign --force --sign "$IDENTITY" --entitlements NativeWidgets/ProductionHost.entitlements "$APP"
codesign --verify --deep --strict "$APP"
python3 - "$APP" <<'PY'
import pathlib,plistlib,subprocess,sys
app=pathlib.Path(sys.argv[1])
for p in [app,app/'Contents/PlugIns/ContextOSWidgets.appex']:
 r=subprocess.run(['codesign','-dv',str(p)],capture_output=True,text=True,check=True)
 assert 'TeamIdentifier=Y56BH9PULD' in r.stderr
 r=subprocess.run(['codesign','-d','--entitlements','-','--xml',str(p)],capture_output=True,check=True)
 d=plistlib.loads(r.stdout);assert d['com.apple.security.application-groups']==['Y56BH9PULD.com.contextos.usage']
 assert set(d)==({'com.apple.security.application-groups'} if p==app else {'com.apple.security.application-groups','com.apple.security.app-sandbox'})
 if p!=app:assert d['com.apple.security.app-sandbox'] is True
print('Existing team, exact approved production group and sandbox boundary verified; not installed.')
PY
