#!/usr/bin/env python3
"""Validate a local bundle; --distribution additionally requires Apple trust checks.

Version probes do not read user state. No signing, uploads or installation occur.
"""
import argparse
import os
import pathlib
import plistlib
import re
import subprocess


class InvalidBundle(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidBundle(message)


def run(*command, timeout=20):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, " ".join(command[:2]) + ": " + (result.stderr or result.stdout).strip())
    return result.stdout.strip()


def load_info(bundle):
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    require(isinstance(info, dict), 'Info.plist must be a dictionary')
    return info


def architectures(binary, app):
    require(binary.is_file() and not binary.is_symlink(), 'Missing or linked executable: ' + str(binary))
    require(binary.resolve().is_relative_to(app), 'Executable leaves the bundle: ' + str(binary))
    require(os.access(binary, os.X_OK), 'Executable permission missing: ' + str(binary))
    values = set(run('/usr/bin/lipo', '-archs', str(binary)).split())
    require(bool(values) and values <= {'arm64', 'x86_64'}, 'Unsupported executable architectures: ' + str(binary))
    return values


def signing_details(target):
    result = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(target)], capture_output=True, text=True, timeout=20)
    require(result.returncode == 0, 'Cannot inspect signature: ' + str(target))
    return result.stderr


def verify(app, distribution=False):
    app = app.resolve()
    info = load_info(app)
    require(info.get('CFBundleIdentifier') == 'com.contextos.app', 'Incorrect host bundle identifier')
    require(info.get('CFBundleExecutable') == 'ContextOSApp', 'Incorrect host executable')
    require(info.get('CFBundlePackageType') == 'APPL', 'Incorrect host package type')
    require(info.get('LSMinimumSystemVersion') == '14.0', 'Unexpected minimum macOS version')
    require(info.get('LSUIElement') is True, 'Host must remain a menu-bar app')
    version, build = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
    require(isinstance(version, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Invalid release version')
    require(isinstance(build, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', build), 'Invalid build version')
    targets = [app]
    expected_arch = None
    for relative in ['MacOS/ContextOSApp', 'Resources/contextos', 'Resources/contextos-mcp']:
        binary = app / 'Contents' / relative
        found = architectures(binary, app)
        if expected_arch is None:
            expected_arch = found
        require(found == expected_arch, 'Host/CLI/MCP architecture mismatch')
        if relative.startswith('Resources/'):
            require(run(str(binary), '--version', timeout=10) == version, 'Bundled executable version mismatch: ' + relative)
            targets.append(binary)
    for relative in ['THIRD_PARTY_NOTICES.md', 'PRIVACY.md', 'INSTALL.md', 'ThirdPartyLicenses/swift-argument-parser.txt']:
        resource = app / 'Contents/Resources' / relative
        require(resource.is_file() and resource.resolve().is_relative_to(app), 'Required resource missing or external: ' + relative)
    plugins = app / 'Contents/PlugIns'
    extensions = list(plugins.glob('*.appex')) if plugins.exists() else []
    require(len(extensions) <= 1, 'Unexpected duplicate widget extensions')
    if extensions:
        extension = extensions[0]
        require(extension.name == 'ContextOSWidgets.appex' and not extension.is_symlink(), 'Unexpected widget extension')
        require(extension.resolve().is_relative_to(app), 'Widget leaves the bundle')
        ext = load_info(extension)
        require(ext.get('CFBundleIdentifier') == 'com.contextos.app.widgets', 'Incorrect widget identifier')
        require(ext.get('CFBundleExecutable') == 'ContextOSWidgets', 'Incorrect widget executable')
        require(ext.get('CFBundlePackageType') == 'XPC!', 'Incorrect widget package type')
        require(ext.get('CFBundleShortVersionString') == version and ext.get('CFBundleVersion') == build, 'Host/widget version mismatch')
        extension_info = ext.get('NSExtension')
        require(isinstance(extension_info, dict) and extension_info.get('NSExtensionPointIdentifier') == 'com.apple.widgetkit-extension', 'Incorrect widget extension point')
        require(expected_arch <= architectures(extension / 'Contents/MacOS/ContextOSWidgets', app), 'Widget does not support every host architecture')
        require(ext.get('ContextOSURLScheme') == info.get('ContextOSURLScheme') == 'contextos', 'Host/widget URL scheme mismatch')
        group = info.get('ContextOSAppGroup')
        require(group == (ext.get('ContextOSAppGroup') or None), 'Host/widget App Group mismatch')
        if group:
            for target in [app, extension]:
                xml = run('/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(target))
                entitlements = plistlib.loads(xml.encode())
                require(entitlements.get('com.apple.security.application-groups') == [group], 'Signed App Group does not match configuration: ' + str(target))
                if target == extension:
                    require(entitlements.get('com.apple.security.app-sandbox') is True, 'Widget sandbox missing')
        if distribution:
            require(isinstance(group, str) and bool(group) and '$(' not in group, 'Distribution widget has no configured App Group')
        targets.append(extension)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    if distribution:
        team = None
        for target in targets:
            details = signing_details(target)
            require('Authority=Developer ID Application:' in details, 'Public distribution requires Developer ID Application: ' + str(target))
            require(re.search(r'flags=.*\(.*runtime.*\)', details), 'Hardened Runtime missing: ' + str(target))
            match = re.search(r'^TeamIdentifier=(.+)$', details, re.MULTILINE)
            require(match and match.group(1) != 'not set', 'Signing team missing: ' + str(target))
            if team is None:
                team = match.group(1)
            require(match.group(1) == team, 'Nested code uses a different signing team')
            require('Timestamp=' in details, 'Secure signing timestamp missing: ' + str(target))
            xml = run('/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(target))
            if xml:
                require(not plistlib.loads(xml.encode()).get('com.apple.security.get-task-allow'), 'Debugging entitlement is enabled: ' + str(target))
        run('/usr/bin/xcrun', 'stapler', 'validate', str(app), timeout=60)
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app), timeout=60)
    return version, build, sorted(expected_arch), bool(extensions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--distribution', action='store_true', help='Require Developer ID, Hardened Runtime, timestamp, stapled ticket and Gatekeeper acceptance.')
    args = parser.parse_args()
    try:
        version, build, arch, widget = verify(args.app, args.distribution)
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        raise SystemExit('Bundle verification stopped: ' + str(error))
    scope = 'public-distribution trust checks' if args.distribution else 'local integrity (public distribution unverified)'
    print(f'Bundle verified: version {version}, build {build}, {" ".join(arch)}, widget={widget}; {scope}')


if __name__ == '__main__':
    main()
