#!/usr/bin/env python3
"""Verify real MCP framing and argument errors in a disposable sandboxed home."""
import argparse
import json
import pathlib
import select
import tempfile
from benchmark_context import MCP


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    checks = []
    with tempfile.TemporaryDirectory(prefix="contextos-wire-audit-") as directory:
        root = pathlib.Path(directory)
        server = MCP(args.binary, cwd=directory)
        try:
            def exchange(raw):
                server.process.stdin.write(raw + "\n")
                server.process.stdin.flush()
                if not select.select([server.process.stdout], [], [], 5)[0]:
                    raise TimeoutError("MCP failed to answer the invalid request")
                return json.loads(server.process.stdout.readline())

            for raw, code in [("{broken", -32700), ("{}", -32600), ("[]", -32600), ("42", -32600)]:
                response = exchange(raw)
                assert response["id"] is None and response["error"]["code"] == code, response
                checks.append("parse/request error " + raw)

            invalid = [
                {"jsonrpc": "1.0", "id": 1, "method": "ping"},
                {"jsonrpc": "2.0", "id": True, "method": "ping"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": []},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "project_stats", "arguments": {"path": 12}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read_optimized", "arguments": {"query": "x", "token_budget": True}}},
                {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "read_optimized", "arguments": {"query": "x", "fresh": 1}}},
                {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "read_optimized", "arguments": {}}},
                {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "project_stats", "arguments": []}},
            ]
            for request in invalid:
                response = exchange(json.dumps(request))
                assert response.get("error", {}).get("code") in [-32600, -32602], response
                checks.append("reject malformed request " + str(request["id"]))
            assert not (root / ".contextos").exists(), "Invalid requests indexed their fallback working directory"

            server.process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            server.process.stdin.flush()
            response = exchange('{"jsonrpc":"2.0","id":"recovered","method":"ping"}')
            assert response == {"jsonrpc": "2.0", "id": "recovered", "result": {}}, response
            checks.append("valid notification stays silent and ping still responds")

            (root / "entry.py").write_text("def selected():\n    return 'CURRENT_BODY'\n")
            text, _ = server.call("read_optimized", root, query="selected", token_budget=8000.0)
            assert "CURRENT_BODY" in text
            checks.append("valid integral numeric budget and real body delivery")
        finally:
            server.close()
    print(json.dumps({"passed": len(checks), "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
