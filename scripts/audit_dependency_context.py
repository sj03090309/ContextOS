#!/usr/bin/env python3
"""Actual stdio MCP checks of required code across files at small budgets.

Disposable sources and isolated account/analytics state; no AI or network calls.
Use --verify for the candidate, omit it when measuring a known failing baseline.
"""
import argparse
import json
import pathlib
import tempfile
import statistics
from benchmark_context import MCP, estimate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    noise_ts = "\n".join(f"function unused{i}() {{ return 'UNRELATED_NOISE'; }}" for i in range(70))
    noise_py = "\n".join(f"def unused{i}():\n    return 'UNRELATED_NOISE'" for i in range(70))
    noise_swift = "\n".join(f"func unused{i}() {{ print(\"UNRELATED_NOISE\") }}" for i in range(70))
    cases = [
        ("ts-alias-chain", 250, {
            "src/login.ts": "import { verify as check } from './crypto';\nexport const login = (token: string) => check(token);\n" + noise_ts,
            "src/crypto.ts": "import { normalize } from './normalize';\nexport const verify = (token: string) => normalize(token) + 'REQUIRED_VERIFY';\n" + noise_ts,
            "src/normalize.ts": "export const normalize = (token: string) => token.trim() + 'REQUIRED_NORMALIZE';\n" + noise_ts,
            "wrong/crypto.ts": "export const verify = () => 'WRONG_DIRECTORY';\n"
        }, ["=> check(token)", "REQUIRED_VERIFY", "REQUIRED_NORMALIZE"]),
        ("ts-namespace", 200, {
            "login.ts": "import * as crypto from './crypto.js';\nexport const login = (token: string) => crypto.verify(token);\n" + noise_ts,
            "crypto.ts": "export const verify = (token: string) => 'REQUIRED_NAMESPACE';\n" + noise_ts
        }, ["crypto.verify(token)", "REQUIRED_NAMESPACE"]),
        ("python-relative-alias-constant", 250, {
            "pkg/login.py": "from .crypto import verify as check\ndef login(token):\n    return check(token)\n" + noise_py,
            "pkg/crypto.py": "from .policy import KEYS\ndef verify(token):\n    return token in KEYS and 'REQUIRED_PYTHON'\n" + noise_py,
            "pkg/policy.py": "KEYS = {'active': 'REQUIRED_CONSTANT'}\n" + noise_py
        }, ["return check(token)", "REQUIRED_PYTHON", "REQUIRED_CONSTANT"]),
        ("swift-free-and-type-method", 250, {
            "Login.swift": "func login(_ token: String) -> Bool { verifySignature(token) && Rules.allowed(token) }\n" + noise_swift,
            "Signature.swift": "func verifySignature(_ token: String) -> Bool { token == \"REQUIRED_SWIFT\" }\n" + noise_swift,
            "Rules.swift": "enum Rules {\n static func allowed(_ token: String) -> Bool { token == \"REQUIRED_RULE\" }\n}\n" + noise_swift
        }, ["verifySignature(token)", "REQUIRED_SWIFT", "REQUIRED_RULE"]),
        ("reexport-cycle", 250, {
            "login.ts": "import { verify } from './barrel';\nexport const login = (token: string) => verify(token);\nexport const normalize = (token: string) => token.trim() + 'REQUIRED_CYCLE';\n" + noise_ts,
            "barrel.ts": "export { check as verify } from './crypto';\n",
            "crypto.ts": "import { normalize } from './login';\nexport const check = (token: string) => normalize(token) + 'REQUIRED_CYCLE_CHECK';\n" + noise_ts
        }, ["=> verify(token)", "REQUIRED_CYCLE", "REQUIRED_CYCLE_CHECK"]),
        ("default-and-named", 250, {
            "login.ts": "import check, { KEYS as keys } from './crypto';\nexport const login = (token: string) => check(token) && keys.includes(token);\n" + noise_ts,
            "crypto.ts": "export default function validate(token: string) { return token === 'REQUIRED_DEFAULT'; }\nexport const KEYS = ['REQUIRED_NAMED'];\n" + noise_ts
        }, ["check(token)", "REQUIRED_DEFAULT", "REQUIRED_NAMED"])
    ]
    server = MCP(args.binary)
    rows = []
    try:
        server.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "dependency-audit", "version": "1"}})
        with tempfile.TemporaryDirectory(prefix="contextos-dependency-audit-") as directory:
            for name, budget, files, required in cases:
                root = pathlib.Path(directory) / name
                for rel, source in files.items():
                    path = root / rel
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(source)
                bundle, cold_ms = server.call("read_optimized", root, query="login", token_budget=budget, fresh=True)
                timings = [server.call("read_optimized", root, query="login", token_budget=budget, fresh=True)[1] for _ in range(5)]
                present = {text: text in bundle for text in required}
                rows.append({"case": name, "budget": budget, "required": present, "all_required_present": all(present.values()),
                             "unrelated_body_absent": "UNRELATED_NOISE" not in bundle and "WRONG_DIRECTORY" not in bundle,
                             "estimated_tokens": estimate(bundle), "within_budget": estimate(bundle) <= budget,
                             "cold_ms": round(cold_ms, 3), "warm_median_5_ms": round(statistics.median(timings), 3)})
    finally:
        server.close()
    result = {"scope": "Six fixed source-level cross-file requirements, 200 or 250 local estimated tokens; not model task accuracy", "cases": rows,
              "totals": {"cases": len(rows), "complete_required_code": sum(row["all_required_present"] for row in rows),
                         "all_within_budget": all(row["within_budget"] for row in rows),
                         "all_unrelated_bodies_absent": all(row["unrelated_body_absent"] for row in rows)}}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["totals"]))
    if args.verify:
        assert result["totals"]["complete_required_code"] == len(rows), result
        assert result["totals"]["all_within_budget"] and result["totals"]["all_unrelated_bodies_absent"], result


if __name__ == "__main__":
    main()
