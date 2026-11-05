#!/usr/bin/env python3
"""Exercise MCP executable replacement with disposable Swift/stdin fixtures only."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import selectors
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Sources/contextos-mcp/MCPHotReload.swift'
BINARY = None
FIXTURE = r'''
import Foundation
import Darwin

@main struct FixtureMain {
    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    static func main() {
        #if GEN_A
        let generation = "A"
        #else
        let generation = "B"
        #endif
        #if TOOL_INCOMPATIBLE
        let schema: [String: Any] = ["type": "object", "required": ["different"]]
        #else
        let schema: [String: Any] = ["type": "object", "properties": [:]]
        #endif
        var tools: [[String: Any]] = [["name": "fixture", "description": generation,
                                      "inputSchema": schema]]
        #if !GEN_A
        tools.append(["name": "additional_fixture", "inputSchema": ["type": "object"]])
        #endif
        let contract = try! JSONSerialization.data(withJSONObject: ["schema_version": 1,
            "mcp_protocol_version": "2024-11-05", "mcp_tools": tools, "version": generation])
        if CommandLine.arguments.contains("--contract") {
            #if CONTRACT_HANG
            Thread.sleep(forTimeInterval: 30)
            #endif
            FileHandle.standardOutput.write(contract)
            FileHandle.standardOutput.write(Data([10]))
            return
        }
        #if STARTUP_DELAY
        let gate = ProcessInfo.processInfo.environment["CONTEXTOS_FIXTURE_STARTUP_GATE"]!
        emit(["event": "booting", "generation": generation, "pid": getpid()])
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: gate) {
            if ProcessInfo.processInfo.systemUptime >= deadline { exit(7) }
            usleep(1_000)
        }
        #endif
        // This closure is compiled into this test executable. The production
        // MCP server has no command-line or environment trust bypass.
        let input = MCPStdioInput(contract: contract,
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            candidateValidator: { _ in true })
        emit(["event": "ready", "generation": generation, "pid": getpid(), "resumed": input.resumedSession])
        if input.resumedSession {
            emit(["jsonrpc": "2.0", "method": "fixture/resumed", "params": ["generation": generation, "pid": getpid()]])
        }
        while let line = input.nextLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                emit(["event": "invalid", "raw": line]); continue
            }
            if request["method"] as? String == "initialized" {
                input.markInitialized()
                emit(["event": "initialized", "generation": generation, "pid": getpid()])
                continue
            }
            if request["method"] as? String == "initialize" {
                input.markNegotiated()
            }
            if request["method"] as? String == "slow" {
                emit(["event": "started", "id": request["id"] ?? NSNull(), "generation": generation])
                Thread.sleep(forTimeInterval: 0.7)
            }
            emit(["jsonrpc": "2.0", "id": request["id"] ?? NSNull(),
                  "result": ["generation": generation, "pid": getpid(), "raw": line]])
        }
    }
}
'''


def descendants(pid):
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid='], check=True, capture_output=True, text=True)
    pairs = [tuple(map(int, line.split())) for line in result.stdout.splitlines() if line.strip()]
    found, frontier = set(), {pid}
    while frontier:
        children = {child for child, parent in pairs if parent in frontier} - found
        found.update(children)
        frontier = children
    return found


def alive(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
    return result.returncode == 0 and not result.stdout.strip().startswith('Z')


def wait_until(predicate, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.03)
    return bool(predicate())


class Client:
    def __init__(self, executable, directory, fixture=True):
        self.stderr_path = directory / 'fixture-stderr.log'
        self.stderr = self.stderr_path.open('wb')
        environment = dict(os.environ)
        environment.pop('CONTEXTOS_MCP_RESUMED_SESSION', None)
        home = directory / 'disposable-home'
        home.mkdir(exist_ok=True)
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home),
                           CONTEXTOS_FIXTURE_STARTUP_GATE=str(directory / 'startup-gate'))
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, bufsize=0, start_new_session=True, env=environment)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.messages = []
        self.ready = self.until(lambda item: item.get('event') == 'ready') if fixture else None

    def send_raw(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def send(self, method, identity=None, **params):
        request = {'jsonrpc': '2.0', 'method': method}
        if identity is not None:
            request['id'] = identity
        if params:
            request['params'] = params
        self.send_raw(json.dumps(request, ensure_ascii=False).encode() + b'\n')

    def read(self, timeout=4):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError('Fixture response timeout; stderr: ' + self.stderr_path.read_text())
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError('Fixture stdout closed; stderr: ' + self.stderr_path.read_text())
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\n', 1)
        message = json.loads(line)
        self.messages.append(message)
        return message

    def until(self, predicate, timeout=4):
        deadline = time.monotonic() + timeout
        while True:
            value = self.read(max(0.01, deadline - time.monotonic()))
            if predicate(value):
                return value

    def response(self, identity, timeout=4):
        return self.until(lambda item: item.get('id') == identity and 'result' in item, timeout)['result']

    def initialize(self):
        self.send('initialize', 0)
        response = self.response(0)
        self.send('initialized')
        self.until(lambda item: item.get('event') == 'initialized')
        return response

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1)
        # Also clean a failed test's probe descendants. Each fixture owns a
        # separate process group; no real MCP/app process is targeted.
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.selector.close()
        self.process.stdout.close()
        self.stderr.close()


class MCPHotReloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / '.audit').mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix='mcp-hot-reload-', dir=ROOT / '.audit')
        cls.directory = Path(cls.temporary.name)
        cls.addClassCleanup(cls.temporary.cleanup)
        fixture = cls.directory / 'Fixture.swift'
        fixture.write_text(FIXTURE)
        cls.binaries = {}
        for name, defines in [('A', ['GEN_A']), ('B', []),
                              ('incompatible', ['TOOL_INCOMPATIBLE']), ('hang', ['CONTRACT_HANG']),
                              ('startup', ['GEN_A', 'STARTUP_DELAY'])]:
            binary = cls.directory / ('fixture-' + name)
            command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                       str(SOURCE), str(fixture), '-o', str(binary)]
            for define in defines:
                command += ['-D', define]
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError('Fixture compilation failed:\n' + result.stderr)
            cls.binaries[name] = binary

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix='case-', dir=self.directory))
        self.executable = self.case / 'fixture-mcp'
        self.replace(self.binaries['A'])
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        shutil.rmtree(self.case)

    def replace(self, source, mode=0o755):
        stage = self.case / 'candidate'
        shutil.copyfile(source, stage)
        stage.chmod(mode)
        stage.replace(self.executable)

    def start(self, initialized=True):
        client = Client(self.executable, self.case)
        self.clients.append(client)
        self.assertEqual(client.ready['generation'], 'A')
        self.assertFalse(client.ready['resumed'])
        if initialized:
            client.initialize()
        return client

    def test_idle_replacement_keeps_pid_fds_and_notifies_initialized_session(self):
        client = self.start()
        pid = client.process.pid
        self.replace(self.binaries['B'])
        client.send('ping', 1)
        response = client.response(1)
        self.assertEqual((response['generation'], response['pid']), ('B', pid))
        resumed = [item for item in client.messages if item.get('method') == 'fixture/resumed']
        self.assertEqual(len(resumed), 1)
        self.assertEqual(resumed[0]['params']['pid'], pid)
        self.assertIsNone(client.process.poll())

    def test_pipeline_during_slow_request_keeps_both_requests(self):
        client = self.start()
        pipeline = b'{"id":1,"method":"slow"}\n{"id":2,"method":"ping"}\n'
        client.send_raw(pipeline)
        client.until(lambda item: item.get('event') == 'started' and item.get('id') == 1)
        self.replace(self.binaries['B'])
        first, second = client.response(1), client.response(2)
        self.assertEqual(first['generation'], 'A')
        self.assertEqual(second['generation'], 'B')
        self.assertEqual(first['pid'], second['pid'])
        self.assertEqual([item['id'] for item in client.messages if 'result' in item], [0, 1, 2])

    def test_partial_utf8_line_completes_in_old_generation_then_reloads(self):
        client = self.start()
        payload = json.dumps({'id': 1, 'method': 'ping', 'params': {'text': '저장된 문장'}}, ensure_ascii=False).encode()
        midpoint = len(payload) // 2
        client.send_raw(payload[:midpoint])
        time.sleep(0.15)  # Let nextLine consume the partial frame without its newline.
        self.replace(self.binaries['B'])
        client.send_raw(payload[midpoint:] + b'\n')
        response = client.response(1)
        self.assertEqual(response['generation'], 'A')
        self.assertEqual(response['raw'].encode(), payload)
        client.send('ping', 2)
        self.assertEqual(client.response(2)['generation'], 'B')

    def test_pre_handshake_replacement_never_announces_resumed_session(self):
        client = self.start(initialized=False)
        self.replace(self.binaries['B'])
        client.initialize()
        self.assertFalse(any(item.get('method') == 'fixture/resumed' for item in client.messages))
        client.send('ping', 1)
        self.assertEqual(client.response(1)['generation'], 'B')

    def test_startup_replacement_uses_mapped_image_before_input_initialization(self):
        self.replace(self.binaries['startup'])
        client = Client(self.executable, self.case, fixture=False)
        self.clients.append(client)
        booting = client.until(lambda item: item.get('event') == 'booting')
        self.assertEqual(booting['generation'], 'A')
        self.replace(self.binaries['B'])
        # The old process cannot construct MCPStdioInput before this explicit
        # gate, so path replacement always precedes loaded-identity capture.
        (self.case / 'startup-gate').write_text('continue')
        ready = client.until(lambda item: item.get('event') == 'ready')
        self.assertEqual(ready['generation'], 'A')
        client.send('ping', 1)
        response = client.response(1)
        self.assertEqual((response['generation'], response['pid']), ('B', booting['pid']))
        self.assertEqual(client.process.pid, booting['pid'])
        self.assertFalse(any(item.get('method') == 'fixture/resumed' for item in client.messages))

    def test_unexecutable_and_incompatible_candidates_keep_current_generation(self):
        for name, mode in [('B', 0o644), ('incompatible', 0o755)]:
            with self.subTest(candidate=name, mode=oct(mode)):
                self.replace(self.binaries['A'])
                client = self.start()
                self.replace(self.binaries[name], mode)
                client.send('ping', 1)
                response = client.response(1)
                self.assertEqual((response['generation'], response['pid']), ('A', client.process.pid))
                client.send('ping', 2)
                self.assertEqual(client.response(2)['generation'], 'A')
                client.close()
                self.clients.remove(client)

    def test_malformed_contract_is_probed_once_without_idle_spin(self):
        client = self.start()
        probes = self.case / 'probe-count'
        malformed = self.case / 'malformed'
        malformed.write_text('#!/bin/sh\nprintf x >> ' + shlex.quote(str(probes)) + '\nprintf invalid-json\n')
        self.replace(malformed)
        for identity in range(1, 5):
            client.send('ping', identity)
            self.assertEqual(client.response(identity)['generation'], 'A')
        time.sleep(0.2)
        self.assertEqual(probes.read_text(), 'x')
        self.assertFalse(descendants(client.process.pid))

    def test_inherited_probe_stdout_cannot_extend_the_read_deadline(self):
        client = self.start()
        child_pid_file = self.case / 'inherited-stdout-child'
        candidate = self.case / 'inherited-stdout'
        candidate.write_text('#!/bin/sh\nsleep 15 &\necho $! > ' + shlex.quote(str(child_pid_file))
                             + '\nprintf "{}"\nexit 0\n')
        self.replace(candidate)
        child_pid = None
        try:
            start = time.monotonic()
            client.send('ping', 1)
            self.assertEqual(client.response(1, timeout=6)['generation'], 'A')
            self.assertLess(time.monotonic() - start, 5)
            child_pid = int(child_pid_file.read_text())
        finally:
            if child_pid is None and child_pid_file.exists():
                child_pid = int(child_pid_file.read_text())
            # This deliberately malformed contract executable forks. Production
            # ContextOS --contract does not; descendant cleanup is fixture-owned.
            if child_pid is not None and alive(child_pid):
                os.kill(child_pid, signal.SIGKILL)

    def test_contract_probe_timeout_is_bounded_and_reaped(self):
        client = self.start()
        self.replace(self.binaries['hang'])
        start = time.monotonic()
        client.send('ping', 1)
        self.assertEqual(client.response(1, timeout=6)['generation'], 'A')
        self.assertLess(time.monotonic() - start, 5)
        self.assertFalse(descendants(client.process.pid))
        start = time.monotonic()
        client.send('ping', 2)
        self.assertEqual(client.response(2)['generation'], 'A')
        self.assertLess(time.monotonic() - start, 1)

    def test_crlf_and_eof_tail_are_not_dropped(self):
        client = self.start()
        payload = '{"id":1,"method":"ping","params":{"text":"한글"}}'
        client.send_raw(payload.encode() + b'\r\n')
        self.assertEqual(client.response(1)['raw'], payload)
        client.send_raw(b'{"id":2,"method":"ping"}')
        client.process.stdin.close()
        self.assertEqual(client.response(2)['generation'], 'A')
        self.assertEqual(client.process.wait(timeout=3), 0)
        self.assertFalse(descendants(client.process.pid))

    def test_parent_termination_during_probe_leaves_no_running_probe(self):
        client = self.start()
        self.replace(self.binaries['hang'])
        client.send('ping', 1)
        children = set()

        def observed_probe():
            children.update(descendants(client.process.pid))
            return bool(children)

        self.assertTrue(wait_until(observed_probe, timeout=2), 'Expected an isolated contract probe child')
        client.process.terminate()
        client.process.wait(timeout=2)
        self.assertTrue(wait_until(lambda: not any(alive(pid) for pid in children), timeout=4),
                        'Contract probe remained alive after the MCP process terminated')

    def test_ordinary_ping_latency_is_small_without_replacements(self):
        client = self.start()
        times = []
        for identity in range(1, 31):
            start = time.monotonic()
            client.send('ping', identity)
            self.assertEqual(client.response(identity)['generation'], 'A')
            times.append((time.monotonic() - start) * 1000)
        # A loose bound detects an accidental per-request contract subprocess,
        # while tolerating a busy shared development machine.
        self.assertLess(statistics.median(times), 100)
        print('Ordinary ping median: %.3f ms' % statistics.median(times), flush=True)

    def real_client(self):
        if BINARY is None:
            self.skipTest('Pass --binary <contextos-mcp> to exercise the production signature validator')
        contents = self.case / 'ContextOS.app/Contents'
        resources = contents / 'Resources'
        resources.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.contextos.app'}))
        self.executable = resources / 'contextos-mcp'
        self.replace(BINARY)
        client = Client(self.executable, self.case, fixture=False)
        self.clients.append(client)
        return client

    def real_initialize(self, client, identity):
        client.send('initialize', identity, protocolVersion='2024-11-05', capabilities={},
                    clientInfo={'name': 'disposable-hot-reload-test', 'version': '1'})
        result = client.response(identity)
        self.assertTrue(result['capabilities']['tools']['listChanged'])
        client.send('notifications/initialized')
        # This response confirms the preceding notification was consumed.
        client.send('ping', identity + 1)
        self.assertEqual(client.response(identity + 1), {})

    def mapped_text_inodes(self, client):
        result = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(client.process.pid), '-d', 'txt', '-F', 'fin'],
                                check=True, capture_output=True, text=True, timeout=10)
        records, record = [], {}
        for line in result.stdout.splitlines():
            if line.startswith('f'):
                if record:
                    records.append(record)
                record = {}
            elif line[:1] in ('i', 'n'):
                record[line[0]] = line[1:]
        if record:
            records.append(record)
        return {int(row['i']) for row in records if row.get('i', '').isdigit()
                and row.get('n', '').split(' (deleted)', 1)[0] == str(self.executable)}

    def test_real_default_signature_reload_keeps_connection_and_updates_catalog(self):
        client = self.real_client()
        self.real_initialize(client, 10)
        client.send('tools/list', 12)
        before = client.response(12)['tools']
        old_inode = self.executable.stat().st_ino
        self.assertIn(old_inode, self.mapped_text_inodes(client))
        self.replace(BINARY)  # Same signed code/CDHash, distinct installed inode.
        new_inode = self.executable.stat().st_ino
        self.assertNotEqual(old_inode, new_inode)
        client.send('ping', 13)
        self.assertEqual(client.response(13), {})
        self.assertIsNone(client.process.poll())
        notifications = [item for item in client.messages if item.get('method') == 'notifications/tools/list_changed']
        self.assertEqual(len(notifications), 1)
        self.assertIn(new_inode, self.mapped_text_inodes(client))
        client.send('tools/list', 14)
        self.assertEqual(client.response(14)['tools'], before)

    def test_real_invalid_or_premature_handshake_does_not_notify(self):
        client = self.real_client()
        client.send('notifications/initialized')
        client.send_raw(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":[]}\n')
        invalid = client.until(lambda item: item.get('id') == 1)
        self.assertEqual(invalid['error']['code'], -32602)
        self.replace(BINARY)
        client.send('ping', 2)
        self.assertEqual(client.response(2), {})
        self.assertFalse(any(item.get('method') == 'notifications/tools/list_changed' for item in client.messages))
        self.assertIn(self.executable.stat().st_ino, self.mapped_text_inodes(client))
        self.real_initialize(client, 20)
        self.replace(BINARY)
        client.send('ping', 22)
        self.assertEqual(client.response(22), {})
        self.assertEqual(sum(item.get('method') == 'notifications/tools/list_changed' for item in client.messages), 1)

    def test_real_update_between_initialize_reply_and_ready_keeps_handshake(self):
        client = self.real_client()
        client.send('initialize', 30, protocolVersion='2024-11-05', capabilities={},
                    clientInfo={'name': 'handshake-window-fixture', 'version': '1'})
        negotiated = client.response(30)
        self.assertTrue(negotiated['capabilities']['tools']['listChanged'])
        pid = client.process.pid
        original_inode = self.executable.stat().st_ino
        self.replace(BINARY)
        second_inode = self.executable.stat().st_ino
        self.assertNotEqual(original_inode, second_inode)
        # The old image must consume ready before replacing itself. The queued
        # request then uses the new image on these exact pipes and this PID.
        client.send_raw(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
                        b'{"jsonrpc":"2.0","id":31,"method":"ping"}\n')
        self.assertEqual(client.response(31), {})
        self.assertEqual(client.process.pid, pid)
        self.assertIsNone(client.process.poll())
        self.assertIn(second_inode, self.mapped_text_inodes(client))
        self.assertEqual(sum(item.get('method') == 'notifications/tools/list_changed' for item in client.messages), 1)

        # A lost negotiated phase used to suppress not only this notification
        # but every later update. Exercise a third installed inode as well.
        self.replace(BINARY)
        third_inode = self.executable.stat().st_ino
        self.assertNotEqual(second_inode, third_inode)
        client.send('ping', 32)
        self.assertEqual(client.response(32), {})
        self.assertIn(third_inode, self.mapped_text_inodes(client))
        self.assertEqual(sum(item.get('method') == 'notifications/tools/list_changed' for item in client.messages), 2)


def main():
    global SOURCE, BINARY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=SOURCE, help='Path to MCPHotReload.swift')
    parser.add_argument('--binary', type=Path, help='Also test a copied real contextos-mcp with its default signature validator')
    args = parser.parse_args()
    SOURCE = args.source.resolve()
    BINARY = args.binary.resolve() if args.binary else None
    if sys.platform != 'darwin':
        print('Skipped: MCP hot reload is a macOS-only runtime feature.')
        return
    if not SOURCE.is_file():
        raise SystemExit('Missing helper source: ' + str(SOURCE))
    if BINARY is not None and (not BINARY.is_file() or not os.access(BINARY, os.X_OK)):
        raise SystemExit('Missing executable MCP binary: ' + str(BINARY))
    unittest.main(argv=[__file__, '-v'])


if __name__ == '__main__':
    main()
