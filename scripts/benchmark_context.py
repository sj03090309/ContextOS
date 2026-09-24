#!/usr/bin/env python3
"""Exercise the real stdio MCP binary with disposable, deterministic projects.

Usage: python3 scripts/benchmark_context.py --binary /path/to/contextos-mcp
Requires macOS sandbox-exec: benchmark deliveries must not change real analytics.
Token figures use ContextOS's local text estimate, not a provider tokenizer.
"""
import argparse
import json
import math
import pathlib
import shutil
import statistics
import subprocess
import tempfile
import time


class MCP:
    def __init__(self, binary):
        sandbox = shutil.which("sandbox-exec")
        if sandbox is None:
            raise RuntimeError("sandbox-exec is required to isolate usage analytics")
        analytics = pathlib.Path.home() / "Library/Application Support/ContextOS"
        profile = '(version 1)(allow default)(deny file-write* (subpath ' + json.dumps(str(analytics)) + '))'
        self.process = subprocess.Popen(
            [sandbox, "-p", profile, str(pathlib.Path(binary).resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1)
        self.counter = 0

    def request(self, method, params):
        self.counter += 1
        request = {"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params}
        start = time.perf_counter()
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        # A bounded wait makes a dead or wedged server a benchmark failure.
        import select
        if not select.select([self.process.stdout], [], [], 30)[0]:
            raise TimeoutError("MCP did not respond within 30 seconds")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(self.process.stderr.read())
        response = json.loads(line)
        assert response["id"] == self.counter, response
        assert "error" not in response, response
        return response["result"], (time.perf_counter() - start) * 1000

    def call(self, name, root, **args):
        result, elapsed = self.request("tools/call", {"name": name, "arguments": {"path": str(root), **args}})
        assert not result.get("isError"), result
        return result["content"][0]["text"], elapsed

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()


def estimate(text):
    # Fixtures use ASCII and precomposed Hangul, so Python len == Swift .count.
    return math.ceil(len(text) / 4)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--output")
    parser.add_argument("--verify", action="store_true", help="Fail if the fixed MCP behavior regresses")
    args = parser.parse_args()
    server = MCP(args.binary)
    report = {}
    try:
        server.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                      "clientInfo": {"name": "contextos-benchmark", "version": "1"}})
        with tempfile.TemporaryDirectory(prefix="contextos-benchmark-") as directory:
            base = pathlib.Path(directory)

            def project(name, files):
                root = base / name
                for path, body in files.items():
                    destination = root / path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_text(body)
                return root

            root = project("filenames", {
                "Package.swift": "let package = 1\n",
                "Tests/PackageTests.swift": "func package() {}\n",
                "Sources/Noise.swift": "func unrelated() {}\n"})
            text, elapsed = server.call("get_relevant_context", root, query="Package.swift", token_budget=8000)
            paths = [line.strip().split("  (")[0][2:] for line in text.splitlines() if line.startswith("  - ")]
            report["explicit_filename"] = {"selected": paths, "cold_ms": round(elapsed, 2)}
            timings = [server.call("get_relevant_context", root, query="Package.swift", token_budget=8000)[1]
                       for _ in range(10)]
            report["explicit_filename"]["warm_median_ms"] = round(statistics.median(timings), 2)

            large = "def target():\n    return 'NEEDED_BODY'\n\ndef unrelated():\n" + "    print('unrelated payload')\n" * 600
            root = project("large", {"large.py": large})
            text, elapsed = server.call("read_optimized", root, query="target", token_budget=250)
            report["large_file_small_budget"] = {
                "budget": 250, "body_present": "NEEDED_BODY" in text,
                "response_tokens": estimate(text), "whole_source_tokens": estimate(large),
                "response_bytes": len(text.encode()), "elapsed_ms": round(elapsed, 2)}
            first, _ = server.call("read_optimized", root, query="target", token_budget=8000, fresh=True)
            # Establish a served body even on a baseline that missed the small-budget request.
            server.call("read_optimized", root, query="target", token_budget=8000)
            repeat, _ = server.call("read_optimized", root, query="target", token_budget=8000)
            fresh, _ = server.call("read_optimized", root, query="target", token_budget=8000, fresh=True)
            report["session_dedup"] = {"first_tokens": estimate(first), "repeat_tokens": estimate(repeat),
                                       "repeat_body_present": "NEEDED_BODY" in repeat,
                                       "fresh_body_present": "NEEDED_BODY" in fresh}

            root = project("budget", {f"module{i}.py": "def target():\n" + "    print('payload')\n" * 10 for i in range(10)})
            report["complete_response_budgets"] = []
            for budget in [1, 30, 100, 250, 500]:
                text, _ = server.call("read_optimized", root, query="target", token_budget=budget, fresh=True)
                report["complete_response_budgets"].append({"budget": budget, "response_tokens": estimate(text)})

            first, _ = server.call("index_project", root)
            second, _ = server.call("index_project", root)
            report["forced_reindex"] = {"first": first.splitlines()[1], "second": second.splitlines()[1]}

            for name, arguments in [
                ("project_stats", {}), ("get_project_rules", {}), ("restore_session", {})
            ]:
                text, _ = server.call(name, root, **arguments)
                report[name] = {"responded": bool(text)}
    finally:
        server.close()
    rendered = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        pathlib.Path(args.output).write_text(rendered + "\n")
    print(rendered)
    if args.verify:
        assert report["explicit_filename"]["selected"] == ["Package.swift"]
        assert report["large_file_small_budget"]["body_present"]
        assert report["session_dedup"]["repeat_tokens"] < report["session_dedup"]["first_tokens"]
        assert not report["session_dedup"]["repeat_body_present"]
        assert report["session_dedup"]["fresh_body_present"]
        assert all(item["response_tokens"] <= item["budget"] for item in report["complete_response_budgets"])
        assert "symbols: 10" in report["forced_reindex"]["second"]


if __name__ == "__main__":
    main()
