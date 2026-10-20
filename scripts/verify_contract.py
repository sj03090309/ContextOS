#!/usr/bin/env python3
"""Check real CLI/MCP binaries without connecting an agent or reading user logs.

--preparation also proves that every protected entry point fails without writing
the disposable home/project. A passing preparation check is not Windows support.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def run(binary, args, env, *, stdin=""):
    return subprocess.run([str(binary), *args], input=stdin, capture_output=True,
                          text=True, encoding="utf-8", errors="strict", env=env, timeout=15)


def successful(binary, args, env):
    result = run(binary, args, env)
    if result.returncode != 0:
        raise RuntimeError(f"{binary.name} {' '.join(args)} failed")
    return result.stdout.strip()


def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--mcp", type=Path, required=True)
    parser.add_argument("--preparation", action="store_true")
    parser.add_argument("--compare-to", type=Path, help="Contract JSON saved from the other platform/profile")
    parser.add_argument("--contract-output", type=Path)
    args = parser.parse_args()
    cli, mcp = args.cli.resolve(), args.mcp.resolve()
    with tempfile.TemporaryDirectory(prefix="contextos-contract-") as directory:
        fixture = Path(directory)
        home, project = fixture / "home", fixture / "project"
        home.mkdir()
        project.mkdir()
        (home / ".claude.json").write_text('{"private":"DUMMY_PRIVATE_VALUE"}', encoding="utf-8")
        (project / ".env").write_text("DUMMY_PRIVATE_VALUE", encoding="utf-8")
        (project / "login.py").write_text("def login():\n    return True\n", encoding="utf-8")
        env = dict(os.environ, CFFIXED_USER_HOME=str(home))
        before = snapshot(fixture)
        contract = json.loads(successful(cli, ["contract"], env))
        assert json.loads(successful(mcp, ["--contract"], env)) == contract, "CLI/MCP contract differs"
        assert successful(cli, ["--version"], env) == contract["version"]
        assert successful(mcp, ["--version"], env) == contract["version"]
        if args.compare_to:
            assert json.loads(args.compare_to.read_text(encoding="utf-8")) == contract, "Platform/profile contract differs"
        help_text = successful(cli, ["--help"], env)
        for name in contract["cli_commands"]:
            assert any(line.strip().startswith(name + " ") for line in help_text.splitlines()), f"Missing CLI command: {name}"
        doctor = run(cli, ["doctor", "--json"], env)
        report = json.loads(doctor.stdout)
        assert report["version"] == contract["version"] and report["agentToolCallVerified"] is False
        assert report["readyToConnect"] is (not args.preparation), "Unexpected installation readiness"
        assert (doctor.returncode == 0) is (not args.preparation)
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": contract["mcp_protocol_version"]}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            {"jsonrpc": "2.0", "id": 3, "method": "ping", "params": {}}
        ]
        if args.preparation:
            for index, tool in enumerate(contract["mcp_tools"], start=4):
                requests.append({"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {
                    "name": tool["name"], "arguments": {"path": str(project), "query": "login", "token_budget": 250}}})
        response = run(mcp, [], env, stdin="".join(json.dumps(r) + "\n" for r in requests))
        assert response.returncode == 0, "MCP did not exit cleanly on stdin EOF"
        messages = [json.loads(line) for line in response.stdout.splitlines()]
        assert [m["id"] for m in messages] == [r["id"] for r in requests], "Missing/extra JSON-RPC response"
        assert all(m.get("jsonrpc") == "2.0" and "error" not in m for m in messages)
        assert messages[0]["result"]["serverInfo"]["version"] == contract["version"]
        assert messages[0]["result"]["protocolVersion"] == contract["mcp_protocol_version"]
        assert messages[1]["result"]["tools"] == contract["mcp_tools"], "Actual tools/list differs from contract"
        if args.preparation:
            for message in messages[3:]:
                result = message["result"]
                assert result.get("isError") is True
                assert "preparation build" in result["content"][0]["text"]
            commands = [
                ["connect", "--agent", "Codex", "--apply"],
                ["disconnect", "--agent", "Codex", "--apply"],
                ["restore-settings", "--agent", "Codex", "--apply"],
                ["context", "login", "--path", str(project)],
                ["watch", str(project)],
                ["hook"]
            ]
            for command in commands:
                result = run(cli, command, env, stdin='{"prompt":"login","cwd":' + json.dumps(str(project)) + '}')
                assert result.returncode != 0 and "preparation build" in result.stderr, f"Protected CLI operation succeeded: {command[0]}"
                assert "DUMMY_PRIVATE_VALUE" not in result.stdout + result.stderr
        assert "DUMMY_PRIVATE_VALUE" not in response.stdout + response.stderr
        assert snapshot(fixture) == before, "Contract/preparation check modified home or project"
    if args.contract_output:
        args.contract_output.write_text(json.dumps(contract, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"version": contract["version"], "tool_count": len(contract["mcp_tools"]),
                      "cli_mcp_contract_matches": True, "preparation": args.preparation,
                      "fixture_unchanged": True, "agent_tool_call_verified": False,
                      "windows_runtime_verified": False}, sort_keys=True))


if __name__ == "__main__":
    main()
