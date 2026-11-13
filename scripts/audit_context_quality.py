#!/usr/bin/env python3
"""Reproducible local retrieval/retention audit; no model or network calls.

Use a fixed git archive as --corpus for before/after comparisons. The stdio
client isolates account files and analytics using benchmark_context.MCP.
Labels are task-specific judgments, not a calibrated accuracy benchmark.
"""
import argparse
import hashlib
import json
import pathlib
import re
import tempfile

from benchmark_context import MCP, estimate


CASES = [
    ("bundle", "ContextService optimizedBundle assembleBundle", "Sources/ContextOSCore/Service/ContextService.swift"),
    ("korean-context", "토큰 예산에 맞는 컨텍스트 요약과 본문 슬라이싱", "Sources/ContextOSCore/Service/ContextService.swift"),
    ("ranking", "ContextOptimizer selectContext ranking import graph", "Sources/ContextOSCore/Optimizer/ContextOptimizer.swift"),
    ("background", "DashboardModel queueTokenRefresh background polling", "Sources/ContextOSApp/DashboardModel.swift"),
    ("watcher", "파일 변경 감시 FileWatcher", "Sources/ContextOSCore/Platform/macOS/FileWatcher.swift"),
    ("scanner", "ProjectScanner gitignore directory pruning", "Sources/ContextOSCore/Indexer/ProjectScanner.swift"),
    ("usage", "AgentSessionReader token usage logs", "Sources/ContextOSCore/Registry/AgentSessionReader.swift"),
    ("concurrent", "ConcurrentUsageReader snapshot accounting", "Sources/ContextOSCore/Registry/ConcurrentUsageReader.swift"),
    ("dedup", "SessionMemory 중복 전달", "Sources/ContextOSCore/Service/SessionMemory.swift"),
    ("mascot", "ContextOSApp MascotRenderer animation", "Sources/ContextOSApp/ContextOSApp.swift"),
    ("parser", "HeuristicParser blockEnd Python", "Sources/ContextOSCore/Indexer/HeuristicParser.swift"),
    ("filename", "Package.swift", "Package.swift"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--corpus", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--budget", type=int, default=4000)
    args = parser.parse_args()
    assert all((args.corpus / path).is_file() for _, _, path in CASES)
    server = MCP(args.binary)
    report = {"scope": "12 hand-labelled ContextOS queries; lexical retrieval, not task success",
              "budget": args.budget, "queries": [], "retention_probes": []}
    try:
        server.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                      "clientInfo": {"name": "local-quality-audit", "version": "1"}})
        # Each binary must build its own parser's index when comparing versions.
        # Otherwise a prior candidate's arrow symbols can contaminate a baseline.
        server.call("index_project", args.corpus)
        for name, query, expected in CASES:
            text, elapsed = server.call("get_relevant_context", args.corpus, query=query, token_budget=args.budget)
            paths = re.findall(r"^  - (.*?)  \(", text, re.MULTILINE)
            bundle, _ = server.call("read_optimized", args.corpus, query=query, token_budget=args.budget, fresh=True)
            body_paths = re.findall(r"^// ===== FILE: (.*?)(?:  \(| =====)", bundle, re.MULTILINE)
            score = re.search(r"Context Score: (\d+)", text)
            report["queries"].append({
                "case": name, "query": query, "labelled_essential_file": expected,
                "selected": paths, "essential_at_1": paths[:1] == [expected],
                "essential_in_first_3": expected in paths[:3], "essential_delivered": expected in body_paths,
                "heuristic_context_score": int(score[1]) if score else 0,
                "bundle_estimated_tokens": estimate(bundle), "within_budget": estimate(bundle) <= args.budget,
                "bundle_sha256": hashlib.sha256(bundle.encode()).hexdigest(), "planning_ms": round(elapsed, 3)})
            report["queries"][-1]["reported_required_omissions"] = "Required code incomplete:" in text

        # Each probe establishes a concrete information requirement beyond file
        # selection. Reporting a miss is intentional; these aren't passing tests.
        padding = "    print('UNRELATED_PAYLOAD')\n" * 150
        probes = [
            ("python-target", "target", "NEEDED_TARGET_BODY",
             {"module.py": "def target():\n    return 'NEEDED_TARGET_BODY'\n\ndef unrelated():\n" + padding}),
            ("same-file-helper", "login", "REQUIRED_SIGNATURE_VALIDATION",
             {"auth.py": "def login(token):\n    return verify_signature(token)\n\ndef verify_signature(token):\n    return 'REQUIRED_SIGNATURE_VALIDATION'\n\ndef unrelated():\n" + padding}),
            ("typescript-arrow", "authorize", "REQUIRED_ACCESS_CHECK",
             {"access.ts": "export const authorize = (user: User) => {\n  return 'REQUIRED_ACCESS_CHECK';\n};\n" + "// unrelated filler\n" * 600}),
            ("swift-type-small-budget", "AccountService", "REQUIRED_ACCOUNT_RULE",
             {"AccountService.swift": "struct AccountService {\n    func login() -> String { return \"REQUIRED_ACCOUNT_RULE\" }\n" + "    // unrelated filler\n" * 600 + "}\n"}),
        ]
        with tempfile.TemporaryDirectory(prefix="contextos-quality-") as directory:
            for name, query, required, files in probes:
                root = pathlib.Path(directory) / name
                root.mkdir()
                for path, body in files.items():
                    (root / path).write_text(body)
                bundle, elapsed = server.call("read_optimized", root, query=query, token_budget=250, fresh=True)
                report["retention_probes"].append({"case": name, "query": query,
                    "required_information_present": required in bundle,
                    "response_estimated_tokens": estimate(bundle), "within_budget": estimate(bundle) <= 250,
                    "elapsed_ms": round(elapsed, 3)})
        rows = report["queries"]
        report["totals"] = {"queries": len(rows),
            "essential_at_1": sum(r["essential_at_1"] for r in rows),
            "essential_in_first_3": sum(r["essential_in_first_3"] for r in rows),
            "essential_delivered": sum(r["essential_delivered"] for r in rows),
            "reported_required_omission_cases": sum(r["reported_required_omissions"] for r in rows),
            "all_responses_within_estimated_budget": all(r["within_budget"] for r in rows + report["retention_probes"]),
            "retention_probes_present": sum(r["required_information_present"] for r in report["retention_probes"])}
    finally:
        server.close()
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["totals"], ensure_ascii=False))


if __name__ == "__main__":
    main()
