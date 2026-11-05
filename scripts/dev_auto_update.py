#!/usr/bin/env python3
"""Local source-save rebuild/install/relaunch service. No downloads or MCP resets."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
KEY = hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
LABEL = 'com.contextos.dev-auto-update.' + KEY
HOME_STATE = Path.home() / 'Library/Application Support/ContextOS/DevAutoUpdate' / KEY
PLIST = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
INPUT_DIRS = ('Sources', 'NativeWidgets', 'scripts', 'ThirdPartyLicenses')
INPUT_FILES = ('Package.swift', 'Package.resolved', 'AppIcon.icns', 'THIRD_PARTY_NOTICES.md',
               'docs/PRIVACY.md', 'docs/INSTALL.md')
IGNORED = {'.build', 'dist', '.git', '.contextos', '__pycache__', 'DerivedData',
           'xcuserdata', '.DS_Store'}
STOP = False


def log(message):
    print(datetime.datetime.now().astimezone().isoformat(timespec='seconds'), message, flush=True)


def snapshot(root=ROOT):
    """Only build inputs; generated products must never trigger another build."""
    paths = [root / name for name in INPUT_FILES]
    for name in INPUT_DIRS:
        for directory, children, files in os.walk(root / name):
            children[:] = sorted(c for c in children if c not in IGNORED and
                                 not (Path(directory) / c).is_symlink())
            paths.extend(Path(directory) / f for f in files if f not in IGNORED and
                         not f.endswith(('.pyc', '.swp', '~')))
    result = {}
    for path in sorted(paths):
        try:
            if path.is_symlink() or not path.is_file():
                continue
            stat = path.stat()
            result[str(path.relative_to(root))] = (stat.st_mtime_ns, stat.st_size,
                                                   stat.st_ino, stat.st_mode)
        except FileNotFoundError:
            continue  # Editors may atomically replace a file during a scan.
    return result


def digest(files, root=ROOT):
    value = hashlib.sha256()
    for name in sorted(files):
        value.update(name.encode() + b'\0')
        value.update(str(files[name][-1]).encode() + b'\0')
        value.update(hashlib.sha256((root / name).read_bytes()).digest())
    return value.hexdigest()


def read_state(folder):
    try:
        return json.loads((folder / 'state.json').read_text())
    except FileNotFoundError:
        return {}


def write_state(folder, state):
    temporary = folder / 'state.tmp'
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(folder / 'state.json')


def info(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        data = plistlib.load(stream)
    if data.get('CFBundleIdentifier') != 'com.contextos.app':
        raise ValueError('Target is not the installed ContextOS app: ' + str(app))
    return data


def command(args, output=None, cancellable=True):
    with subprocess.Popen([str(a) for a in args], cwd=ROOT, stdout=output,
                          stderr=subprocess.STDOUT if output else None,
                          start_new_session=True) as process:
        while process.poll() is None:
            if STOP and cancellable:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                # A shell can exit before its compiler descendants. Reap the
                # entire isolated build group, including any surviving children.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise InterruptedError('Service stopped before installation')
            time.sleep(0.2)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, args)


def signing_identity(app, directory):
    """Reuse the installed certificate, never create credentials or choose a new team."""
    prefix = directory / 'installed-cert-'
    subprocess.run(['/usr/bin/codesign', '-d', '--extract-certificates=' + str(prefix),
                    str(app)], check=True, capture_output=True)
    certificate = Path(str(prefix) + '0')
    if not certificate.is_file():
        raise ValueError('Installed app has no reusable signing certificate')
    sha = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
    identities = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p',
                                 'codesigning'], check=True, capture_output=True, text=True)
    if sha not in identities.stdout:
        raise ValueError('Installed signing identity is unavailable in the local keychain')
    return sha


def build_number(app, state):
    values = [info(app).get('CFBundleVersion', ''), state.get('build', '')]
    numeric = [int(v) for v in values if str(v).isdigit()]
    return str(max(numeric) + 1) if numeric else datetime.datetime.now().strftime('%Y%m%d%H%M%S')


def control(folder, action, app):
    result = subprocess.run([str(folder / 'app-control'), action, str(app)], timeout=25)
    if action == 'check' and result.returncode in (0, 1):
        return result.returncode == 0
    result.check_returncode()


def launch(folder, app):
    subprocess.run(['/usr/bin/open', '-g', '-a', str(app)], check=True, timeout=15)
    for _ in range(20):
        if control(folder, 'check', app):
            time.sleep(1)
            if control(folder, 'check', app):
                return
        time.sleep(0.25)
    raise RuntimeError('Updated app did not stay running')


def install(candidate, app, output):
    result = subprocess.run([sys.executable, str(ROOT / 'scripts/install_app.py'),
                             str(candidate), '--to', str(app)], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output.write(result.stdout)
    output.flush()
    result.check_returncode()
    for line in result.stdout.splitlines():
        if line.startswith('Previous bundle kept at '):
            return Path(line.removeprefix('Previous bundle kept at '))
    return None


def update(app, folder, state, files, fingerprint):
    """Prepare everything while the old app runs; quit only after verification."""
    with tempfile.TemporaryDirectory(prefix='dev-update-', dir=ROOT / 'dist') as temporary:
        work = Path(temporary)
        installed = info(app)
        if installed.get('ContextOSAppGroup') != 'Y56BH9PULD.com.contextos.usage':
            raise ValueError('This development updater requires the existing signed widget installation')
        identity = signing_identity(app, work)
        number = build_number(app, state)
        with (folder / 'build.log').open('w', buffering=1) as output:
            log('Building source changes (installed app stays running).')
            command(['/usr/bin/xcrun', 'swiftc', ROOT / 'scripts/dev_app_control.swift',
                     '-o', folder / 'app-control'], output)
            command(['/usr/bin/xcrun', 'swift', 'build', '-c', 'release'], output)
            binary_dir = subprocess.run(['/usr/bin/xcrun', 'swift', 'build', '-c', 'release',
                                          '--show-bin-path'], cwd=ROOT, check=True,
                                         capture_output=True, text=True).stdout.strip()
            command(['/bin/bash', ROOT / 'scripts/sign_production_widgets.sh', identity,
                     work / 'package', binary_dir, number], output)
            candidate = work / 'package/ContextOS.app'
            command([sys.executable, ROOT / 'scripts/verify_bundle.py', candidate], output)
            if STOP:
                raise InterruptedError('Service stopped before installation')
            if snapshot() != files:
                log('Sources changed during build; waiting for the latest save before installing.')
                return False
            # Normal application termination flushes the app's activity accounting.
            control(folder, 'quit', app)
            backup = None
            try:
                backup = install(candidate, app, output)
                launch(folder, app)
            except Exception:
                if backup:
                    control(folder, 'quit', app)
                    command([sys.executable, ROOT / 'scripts/install_app.py', backup,
                             '--restore', '--to', app], output, cancellable=False)
                launch(folder, app)
                raise
        state.update(fingerprint=fingerprint, build=number, target=str(app),
                     updated_at=datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
                     error=None)
        backups = state.get('backups', [])
        if backup:
            backups.append(str(backup))
        # Preserve the pre-automation baseline and the latest previous build.
        # Only prune backups recorded as created by this service after successful launch.
        retained = backups[:1] + backups[-1:] if len(backups) > 1 else backups
        state['backups'] = list(dict.fromkeys(retained))
        write_state(folder, state)
        for name in backups[1:-1]:
            old = Path(name)
            if old.parent == app.parent and re.fullmatch(r'ContextOS\.previous-[0-9TZ]+-[a-f0-9]{8}\.app', old.name):
                if old.is_dir() and not old.is_symlink():
                    try:
                        info(old)
                        shutil.rmtree(old)
                    except (OSError, ValueError):
                        log('Could not prune a previous development bundle: ' + str(old))
        log('Installed and relaunched ContextOS build ' + number + '. Eligible MCP sessions will load the update before their next request.')
        return True


def run(app, folder, once=False, debounce=2.0):
    global STOP
    STOP = False
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    (ROOT / 'dist').mkdir(exist_ok=True)
    with (folder / 'watcher.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('The development updater is already running for this checkout')
        state = read_state(folder)
        previous = None
        fingerprint = None
        changed_at = time.monotonic()
        attempted = None
        log('Watching ' + str(ROOT) + ' → ' + str(app))
        while not STOP:
            try:
                current = snapshot()
                if current != previous:
                    previous, changed_at = current, time.monotonic()
                    attempted = None
                    fingerprint = None
                if once or time.monotonic() - changed_at >= debounce:
                    if fingerprint is None:
                        fingerprint = digest(current)
                    installed_build = info(app).get('CFBundleVersion')
                    needs_update = (fingerprint != state.get('fingerprint')
                                    or state.get('target') != str(app)
                                    or installed_build != state.get('build'))
                    if needs_update and fingerprint != attempted:
                        attempted = fingerprint
                        deployed = update(app, folder, state, current, fingerprint)
                        if once and not deployed:
                            raise RuntimeError('Sources changed during the build; retry once or use run')
                    elif not needs_update and state.get('error') is not None:
                        # Reverting a failed edit can restore the already installed
                        # source without a rebuild. Its old error is no longer active.
                        state['error'] = None
                        write_state(folder, state)
                        log('Sources match the installed build; cleared the previous update error.')
                    if once:
                        return
            except InterruptedError:
                if once:
                    raise  # A cancelled one-shot did not complete an installation.
                return
            except Exception as error:
                if state.get('error') != str(error):
                    state['error'] = str(error)
                    write_state(folder, state)
                    log('Update failed; see build.log. ' + str(error))
                if once:
                    raise
                # Retry on the next edit, avoiding an endless build/failure loop.
            time.sleep(0.5)


def unload(domain):
    job = domain + '/' + LABEL
    if subprocess.run(['/bin/launchctl', 'print', job], capture_output=True).returncode:
        return
    result = subprocess.run(['/bin/launchctl', 'bootout', job], capture_output=True)
    if result.returncode:
        raise RuntimeError('Could not stop the existing updater; its login registration was kept')
    deadline = time.monotonic() + 185
    while subprocess.run(['/bin/launchctl', 'print', job], capture_output=True).returncode == 0:
        if time.monotonic() >= deadline:
            raise RuntimeError('Updater is still stopping; its login registration was kept')
        time.sleep(0.25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['enable', 'disable', 'status', 'run', 'once'])
    parser.add_argument('--to', type=Path, default=Path('/Applications/ContextOS.app'))
    args = parser.parse_args()
    folder = HOME_STATE
    domain = 'gui/' + str(os.getuid())
    if args.action == 'disable':
        unload(domain)
        PLIST.unlink(missing_ok=True)
        print('Automatic source updates disabled. Installed app and backups kept.')
        return
    if args.action == 'status':
        result = subprocess.run(['/bin/launchctl', 'print', domain + '/' + LABEL], capture_output=True, text=True)
        state = read_state(folder)
        print(json.dumps(dict(enabled=PLIST.exists(), loaded=result.returncode == 0,
                              checkout=str(ROOT), log=str(folder / 'watcher.log'),
                              build_log=str(folder / 'build.log'), **state), indent=2))
        return
    app = args.to.expanduser().absolute()
    if app.name != 'ContextOS.app' or app.is_symlink() or app.resolve() != app:
        raise ValueError('Choose the existing, absolute non-symlink ContextOS.app installation')
    info(app)
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.action == 'enable':
        PLIST.parent.mkdir(parents=True, exist_ok=True)
        data = dict(Label=LABEL, ProgramArguments=[sys.executable, '-u', str(Path(__file__).resolve()),
                                                  'run', '--to', str(app)], WorkingDirectory=str(ROOT),
                    RunAtLoad=True, KeepAlive=True, ThrottleInterval=10, ExitTimeOut=180,
                    StandardOutPath=str(folder / 'watcher.log'), StandardErrorPath=str(folder / 'watcher.log'),
                    EnvironmentVariables={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin'})
        unload(domain)
        PLIST.write_bytes(plistlib.dumps(data))
        subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(PLIST)], check=True)
        print('Automatic source updates enabled at login. Logs: ' + str(folder))
        return
    signal.signal(signal.SIGTERM, lambda *_: request_stop())
    signal.signal(signal.SIGINT, lambda *_: request_stop())
    run(app, folder, once=args.action == 'once')


def request_stop():
    global STOP
    STOP = True


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
