#!/usr/bin/env python3
"""Check only the specified bundle; --version exits without reading user state."""
import argparse
import pathlib
import plistlib
import subprocess

p=argparse.ArgumentParser()
p.add_argument('app',type=pathlib.Path)
args=p.parse_args()
app=args.app.resolve()
with (app/'Contents/Info.plist').open('rb') as stream:
    info=plistlib.load(stream)
assert info['CFBundleIdentifier']=='com.contextos.app'
assert info['LSMinimumSystemVersion']=='14.0'
assert info['LSUIElement'] is True
assert info['CFBundleVersion']==info['CFBundleShortVersionString']
architectures=[]
for relative in ['MacOS/ContextOSApp','Resources/contextos','Resources/contextos-mcp']:
    binary=app/'Contents'/relative
    assert binary.is_file(),relative
    architectures.append(subprocess.check_output(['/usr/bin/lipo','-archs',str(binary)],text=True).strip())
    if relative.startswith('Resources/'):
        version=subprocess.check_output([str(binary),'--version'],text=True,timeout=10).strip()
        assert version==info['CFBundleShortVersionString'],(relative,version)
assert len(set(architectures))==1,architectures
assert set(architectures[0].split()).issubset({'arm64','x86_64'})
for name in ['THIRD_PARTY_NOTICES.md','PRIVACY.md','INSTALL.md']:
    assert (app/'Contents/Resources'/name).is_file(),name
assert (app/'Contents/Resources/ThirdPartyLicenses/swift-argument-parser.txt').is_file()
print('Bundle verified: version '+info['CFBundleShortVersionString']+', '+architectures[0])
