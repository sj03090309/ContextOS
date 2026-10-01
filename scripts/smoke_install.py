#!/usr/bin/env python3
"""Install/update/restore only inside a disposable directory, never the user's app."""
import argparse
import hashlib
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

parser=argparse.ArgumentParser()
parser.add_argument('--app',required=True,type=pathlib.Path)
args=parser.parse_args()
source=args.app.resolve()
installer=pathlib.Path(__file__).with_name('install_app.py').resolve()

def digest(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}

with tempfile.TemporaryDirectory(prefix='contextos-install-test-') as directory:
    root=pathlib.Path(directory)
    target=root/'Applications/ContextOS.app'
    def install(app,restore=False,success=True):
        command=['python3',str(installer),str(app),'--to',str(target)]
        if restore:
            command+=['--restore']
        result=subprocess.run(command,capture_output=True,text=True,timeout=30)
        assert (result.returncode==0)==success,(result.stdout,result.stderr)
    install(source)
    first=digest(target)
    assert first==digest(source)
    install(source)
    backups=list(target.parent.glob('ContextOS.previous-*.app'))
    assert len(backups)==1 and digest(backups[0])==first
    install(backups[0],restore=True)
    assert digest(target)==first
    bad=root/'Bad.app'
    shutil.copytree(source,bad)
    info_path=bad/'Contents/Info.plist'
    with info_path.open('rb') as stream:
        info=plistlib.load(stream)
    info['CFBundleIdentifier']='com.example.unrelated'
    with info_path.open('wb') as stream:
        plistlib.dump(info,stream)
    install(bad,success=False)
    assert digest(target)==first
    (target.parent/'.contextos-install.lock').mkdir()
    install(source,success=False)
    assert digest(target)==first
    (target.parent/'.contextos-install.lock').rmdir()
print('Install smoke passed: fresh install, retained update, previous-app restore, invalid bundle and installer lock. Disposable target only.')
