#!/usr/bin/env python3
"""Development-updater regression checks; all app bundles and commands are fixtures."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location('dev_auto_update', Path(__file__).with_name('dev_auto_update.py'))
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


class DevAutoUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='contextos-dev-update-test-')
        self.root = Path(self.temporary.name)
        self.folder = self.root / 'state'
        self.folder.mkdir()
        (self.root / 'dist').mkdir()
        self.app = self.bundle('Applications/ContextOS.app')
        updater.STOP = False
        self.log = mock.patch.object(updater, 'log')
        self.log.start()

    def tearDown(self):
        self.log.stop()
        updater.STOP = False
        self.temporary.cleanup()

    def write(self, name, contents='fixture'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def bundle(self, name):
        path = self.root / name
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.contextos.app', 'CFBundleVersion': '10',
            'ContextOSAppGroup': 'Y56BH9PULD.com.contextos.usage'}))
        return path

    def prepare_update(self, files=None):
        """Keep fixture filesystem operations real, substitute every external executable."""
        stack = __import__('contextlib').ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(mock.patch.object(updater, 'ROOT', self.root))
        stack.enter_context(mock.patch.object(updater, 'signing_identity', return_value='A' * 40))
        commands = stack.enter_context(mock.patch.object(updater, 'command'))
        process = subprocess.CompletedProcess([], 0, stdout=str(self.root / 'binaries') + '\n')
        stack.enter_context(mock.patch.object(updater.subprocess, 'run', return_value=process))
        stack.enter_context(mock.patch.object(updater, 'snapshot', return_value=files or {'latest': (1,)}))
        controls = stack.enter_context(mock.patch.object(updater, 'control'))
        installs = stack.enter_context(mock.patch.object(updater, 'install'))
        launches = stack.enter_context(mock.patch.object(updater, 'launch'))
        return commands, controls, installs, launches

    def test_snapshot_excludes_products_and_private_indexes(self):
        expected = {'Sources/App/Main.swift', 'NativeWidgets/Widget.swift',
                    'NativeWidgets/ContextOSWidgets.xcodeproj/project.pbxproj',
                    'scripts/package_app.sh', 'Package.swift', 'docs/INSTALL.md'}
        for name in expected:
            self.write(name)
        for name in ['.build/release/app', 'dist/ContextOS.app/app', '.git/HEAD',
                     '.contextos/index.db', 'Sources/.build/generated.swift',
                     'NativeWidgets/DerivedData/generated.swift', 'scripts/__pycache__/x.pyc',
                     'Sources/.contextos/index.db', 'Sources/Main.swift.swp', 'Sources/Main.swift~']:
            self.write(name)
        outside = self.write('unwatched/private.txt')
        (self.root / 'Sources/linked.swift').symlink_to(outside)
        (self.root / 'Sources/linked-directory').symlink_to(outside.parent, target_is_directory=True)
        self.assertEqual(set(updater.snapshot(self.root)), expected)

    def test_atomic_save_deletion_and_content_fingerprint(self):
        path = self.write('Sources/App.swift', 'let value = 1')
        first = updater.snapshot(self.root)
        initial_hash = updater.digest(first, self.root)
        os.utime(path, ns=(path.stat().st_atime_ns, path.stat().st_mtime_ns + 1_000_000))
        touched = updater.snapshot(self.root)
        self.assertNotEqual(first, touched)
        self.assertEqual(initial_hash, updater.digest(touched, self.root))
        replacement = self.write('unwatched/new.swift', 'let value = 2')
        replacement.replace(path)
        replaced = updater.snapshot(self.root)
        self.assertNotEqual(touched, replaced)
        self.assertNotEqual(initial_hash, updater.digest(replaced, self.root))
        path.unlink()
        self.assertNotIn('Sources/App.swift', updater.snapshot(self.root))

    def test_rapid_saves_coalesce_to_last_quiet_snapshot(self):
        clock = [0.0]
        saves = [{'a': (1,)}, {'b': (2,)}, {'c': (3,)}]
        captures = []

        def scan():
            return saves[min(int(clock[0] / 0.5), 2)]

        def installed(*args):
            captures.append(args[3])
            updater.STOP = True
            return True

        with mock.patch.object(updater, 'ROOT', self.root), \
                mock.patch.object(updater, 'snapshot', side_effect=scan), \
                mock.patch.object(updater, 'digest', side_effect=lambda files: str(files)), \
                mock.patch.object(updater, 'update', side_effect=installed), \
                mock.patch.object(updater.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(updater.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            updater.run(self.app, self.folder, debounce=1.0)
        self.assertEqual(captures, [saves[-1]])
        self.assertGreaterEqual(clock[0], 2.0)

    def test_matching_deployed_fingerprint_does_not_rebuild_on_start(self):
        updater.write_state(self.folder, {'fingerprint': 'same', 'build': '10', 'target': str(self.app)})
        with mock.patch.object(updater, 'ROOT', self.root), \
                mock.patch.object(updater, 'snapshot', return_value={}), \
                mock.patch.object(updater, 'digest', return_value='same'), \
                mock.patch.object(updater, 'update') as update:
            updater.run(self.app, self.folder, once=True)
        update.assert_not_called()

    def test_reverting_failed_edit_clears_error_without_reinstalling(self):
        updater.write_state(self.folder, {'fingerprint': 'deployed', 'build': '10',
                                         'target': str(self.app), 'error': 'Earlier build failed'})
        with mock.patch.object(updater, 'ROOT', self.root), \
                mock.patch.object(updater, 'snapshot', return_value={'reverted': (1,)}), \
                mock.patch.object(updater, 'digest', return_value='deployed'), \
                mock.patch.object(updater, 'update') as update:
            updater.run(self.app, self.folder, once=True)
        update.assert_not_called()
        state = updater.read_state(self.folder)
        self.assertIsNone(state['error'])
        self.assertEqual(state['fingerprint'], 'deployed')
        self.assertEqual(state['build'], '10')

    def test_unchanged_idle_loop_hashes_source_only_once(self):
        updater.write_state(self.folder, {'fingerprint': 'same', 'build': '10', 'target': str(self.app)})
        ticks = [0]

        def advance(_seconds):
            ticks[0] += 1
            if ticks[0] == 6:
                updater.STOP = True

        with mock.patch.object(updater, 'ROOT', self.root), \
                mock.patch.object(updater, 'snapshot', return_value={'unchanged': (1,)}), \
                mock.patch.object(updater, 'digest', return_value='same') as digest, \
                mock.patch.object(updater, 'update') as update, \
                mock.patch.object(updater.time, 'sleep', side_effect=advance):
            updater.run(self.app, self.folder, debounce=0)
        self.assertEqual(ticks[0], 6)
        digest.assert_called_once()
        update.assert_not_called()

    def test_one_shot_changed_candidate_reports_failure(self):
        with mock.patch.object(updater, 'ROOT', self.root), \
                mock.patch.object(updater, 'snapshot', return_value={'saved': (1,)}), \
                mock.patch.object(updater, 'digest', return_value='next'), \
                mock.patch.object(updater, 'update', return_value=False) as update:
            with self.assertRaisesRegex(RuntimeError, 'Sources changed during the build'):
                updater.run(self.app, self.folder, once=True)
        update.assert_called_once()
        self.assertIn('Sources changed during the build', updater.read_state(self.folder)['error'])

    def test_cancelled_one_shot_reports_failure(self):
        with mock.patch.object(updater, 'ROOT', self.root), \
                mock.patch.object(updater, 'snapshot', return_value={'saved': (1,)}), \
                mock.patch.object(updater, 'digest', return_value='next'), \
                mock.patch.object(updater, 'update', side_effect=InterruptedError('Service stopped before installation')):
            with self.assertRaisesRegex(InterruptedError, 'stopped before installation'):
                updater.run(self.app, self.folder, once=True)

    def test_failed_unload_keeps_login_registration(self):
        plist = self.write('LaunchAgents/fixture.plist', 'keep this registration')
        responses = [subprocess.CompletedProcess([], 0),
                     subprocess.CompletedProcess([], 5),
                     subprocess.CompletedProcess([], 0)]
        with mock.patch.object(updater, 'PLIST', plist), \
                mock.patch.object(updater, 'HOME_STATE', self.folder), \
                mock.patch.object(updater.sys, 'argv', ['dev_auto_update.py', 'disable']), \
                mock.patch.object(updater.subprocess, 'run', side_effect=responses) as run:
            with self.assertRaisesRegex(RuntimeError, 'login registration was kept'):
                updater.main()
        self.assertEqual(plist.read_text(), 'keep this registration')
        self.assertEqual(run.call_args_list[1].args[0][1], 'bootout')

    def test_disable_waits_for_asynchronous_unload(self):
        plist = self.write('LaunchAgents/fixture.plist', 'registration')
        responses = [subprocess.CompletedProcess([], code) for code in (0, 0, 0, 113)]
        with mock.patch.object(updater, 'PLIST', plist), \
                mock.patch.object(updater, 'HOME_STATE', self.folder), \
                mock.patch.object(updater.sys, 'argv', ['dev_auto_update.py', 'disable']), \
                mock.patch.object(updater.subprocess, 'run', side_effect=responses), \
                mock.patch.object(updater.time, 'sleep'), mock.patch('builtins.print'):
            updater.main()
        self.assertFalse(plist.exists())

    def test_build_failure_never_quits_or_replaces_installed_app(self):
        before = (self.app / 'Contents/Info.plist').read_bytes()
        commands, controls, installs, launches = self.prepare_update()
        commands.side_effect = [None, subprocess.CalledProcessError(1, ['swift', 'build'])]
        with self.assertRaises(subprocess.CalledProcessError):
            updater.update(self.app, self.folder, {}, {'latest': (1,)}, 'next')
        controls.assert_not_called()
        installs.assert_not_called()
        launches.assert_not_called()
        self.assertEqual((self.app / 'Contents/Info.plist').read_bytes(), before)

    def test_save_during_build_discards_candidate_before_app_quit(self):
        _, controls, installs, launches = self.prepare_update(files={'newer': (2,)})
        self.assertFalse(updater.update(self.app, self.folder, {}, {'older': (1,)}, 'old'))
        controls.assert_not_called()
        installs.assert_not_called()
        launches.assert_not_called()

    def test_success_retains_baseline_and_latest_owned_backup_only(self):
        baseline = self.bundle('Applications/ContextOS.previous-20260101T000000Z-00000001.app')
        middle = self.bundle('Applications/ContextOS.previous-20260101T000001Z-00000002.app')
        latest = self.bundle('Applications/ContextOS.previous-20260101T000002Z-00000003.app')
        unowned = self.bundle('Applications/ContextOS.previous-20260101T000003Z-00000004.app')
        commands, controls, installs, launches = self.prepare_update()
        installs.return_value = latest
        state = {'backups': [str(baseline), str(middle)]}
        events = []
        commands.side_effect = lambda *args, **kwargs: events.append('prepare')
        controls.side_effect = lambda *args: events.append('quit')
        installs.side_effect = lambda *args: events.append('install') or latest
        launches.side_effect = lambda *args: events.append('launch')
        self.assertTrue(updater.update(self.app, self.folder, state, {'latest': (1,)}, 'new'))
        self.assertEqual(events[-3:], ['quit', 'install', 'launch'])
        self.assertTrue(baseline.exists())
        self.assertTrue(latest.exists())
        self.assertTrue(unowned.exists())
        self.assertFalse(middle.exists())
        stored = updater.read_state(self.folder)
        self.assertEqual(stored['backups'], [str(baseline), str(latest)])
        self.assertEqual(stored['fingerprint'], 'new')
        self.assertEqual(stored['build'], '11')

    def test_failed_new_launch_restores_backup_and_reopens_app(self):
        backup = self.bundle('Applications/ContextOS.previous-20260101T000000Z-00000001.app')
        commands, controls, installs, launches = self.prepare_update()
        installs.return_value = backup
        launches.side_effect = [RuntimeError('fixture new app failed'), None]
        state = {'fingerprint': 'previous'}
        with self.assertRaisesRegex(RuntimeError, 'fixture new app failed'):
            updater.update(self.app, self.folder, state, {'latest': (1,)}, 'next')
        self.assertEqual(launches.call_count, 2)
        restores = [call for call in commands.call_args_list if '--restore' in call.args[0]]
        self.assertEqual(len(restores), 1)
        self.assertIn(backup, restores[0].args[0])
        self.assertEqual(state['fingerprint'], 'previous')
        self.assertFalse((self.folder / 'state.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
