#!/usr/bin/env python3
"""Explicit local installation with a retained previous bundle. No data cleanup."""
import argparse
import datetime
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

def identity(app):
    with (app/'Contents/Info.plist').open('rb') as stream:
        info=plistlib.load(stream)
    if info.get('CFBundleIdentifier')!='com.contextos.app':
        raise ValueError('Target must be a ContextOS bundle.')
    for relative in ['MacOS/ContextOSApp','Resources/contextos','Resources/contextos-mcp']:
        if not os.access(app/'Contents'/relative,os.X_OK):
            raise ValueError('ContextOS executable missing: '+relative)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=pathlib.Path)
    parser.add_argument('--to',type=pathlib.Path,default=pathlib.Path.home()/'Applications/ContextOS.app')
    parser.add_argument('--restore',action='store_true',help='Restore a retained older bundle; keep the current one as another backup.')
    args=parser.parse_args()
    source=args.app.resolve()
    target=args.to.absolute()
    if target.name!='ContextOS.app' or target.is_symlink() or source==target.resolve():
        raise ValueError('Choose a separate, non-symlink ContextOS.app target.')
    identity(source)
    if target.exists():
        identity(target) # never overwrite an unrelated app or arbitrary directory
    running=subprocess.run(['/usr/bin/pgrep','-f',re.escape(str(target/'Contents/MacOS/ContextOSApp'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if running.returncode==0:
        raise ValueError('Quit the ContextOS app at the target path before installing.')
    target.parent.mkdir(parents=True,exist_ok=True)
    lock=target.parent/'.contextos-install.lock'
    lock.mkdir() # exclusive, fail if another installer is running
    stage=None
    backup=None
    moved=False
    try:
        stage=pathlib.Path(tempfile.mkdtemp(prefix='.contextos-install-',dir=target.parent))
        staged=stage/'ContextOS.app'
        subprocess.run(['/usr/bin/ditto',str(source),str(staged)],check=True)
        identity(staged)
        if not args.restore:
            subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(staged)],check=True)
            subprocess.run(['python3',str(pathlib.Path(__file__).with_name('verify_bundle.py')),str(staged)],check=True)
        if target.exists():
            stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            backup=target.with_name('ContextOS.previous-'+stamp+'-'+uuid.uuid4().hex[:8]+'.app')
            os.replace(target,backup)
            moved=True
        os.replace(staged,target)
        moved=False
        print('Installed '+str(target)+'. No launch, agent-setting edits or data deletion performed.')
        if backup:
            print('Previous bundle kept at '+str(backup))
            print('Restore explicitly with install_app.sh <previous bundle> --restore --to <target>.')
    except BaseException:
        if moved and backup and not target.exists():
            os.replace(backup,target)
        raise
    finally:
        if stage:
            shutil.rmtree(stage)
        lock.rmdir()

if __name__=='__main__':
    try:
        main()
    except (OSError,ValueError,subprocess.CalledProcessError) as error:
        raise SystemExit('Installation stopped: '+str(error))
