#!/usr/bin/env python3
"""Compare real hidden app processes using synthetic logs and isolated homes.

macOS only. Accounts, analytics and network are blocked by sandbox-exec.
CPU is percent of one core; memory is kernel-reported physical footprint.
This is a short workload test, not a battery-duration measurement.
"""
import argparse
import ctypes
import datetime
import json
import os
import pathlib
import sqlite3
import subprocess
import tempfile
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in [
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
        "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time",
        "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins",
        "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten"]]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]


def usage(pid):
    value = Usage()
    if LIBPROC.proc_pid_rusage(pid, 2, ctypes.byref(value)) != 0:
        raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
    return {name: getattr(value, name) for name, _ in Usage._fields_ if name != "uuid"}


def line(kind, payload):
    return json.dumps({"type": kind, "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "payload": payload}) + "\n"


def run(binary, seconds):
    with tempfile.TemporaryDirectory(prefix="contextos-background-") as directory:
        home = pathlib.Path(directory)
        logs = home / ".codex/sessions/2026/10/22"
        logs.mkdir(parents=True)
        for i in range(80):
            body = line("session_meta", {"id": f"synthetic-{i}", "cwd": "/synthetic/contextos"})
            body += line("turn_context", {"model": "synthetic-model"})
            body += line("event_msg", {"type": "task_started"})
            for n in range(1, 301):
                body += line("event_msg", {"type": "token_count", "info": {"total_token_usage": {"total_tokens": n}}})
            (logs / f"rollout-{i:03}.jsonl").write_text(body)
        real = pathlib.Path.home()
        profile = "(version 1)(allow default)(deny network*)"
        for name in [".claude", ".claude.json", ".codex", ".ssh", ".aws", ".contextos-backups",
                     "Library/Application Support/ContextOS", "Library/Group Containers/Y56BH9PULD.com.contextos.usage"]:
            profile += "(deny file-read* file-write* (subpath " + json.dumps(str(real / name)) + "))"
        with (home / "app.log").open("w") as output:
            process = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, str(binary.resolve())],
                stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                env=dict(os.environ, CFFIXED_USER_HOME=str(home)))
            try:
                time.sleep(10)
                assert process.poll() is None, (home / "app.log").read_text()[-2000:]
                database = home / "Library/Application Support/ContextOS/usage.sqlite"
                assert database.is_file(), "App did not use the isolated analytics home"
                with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
                    rows = db.execute("SELECT path, size FROM session_cache").fetchall()
                assert len(rows) == 80 and all(pathlib.Path(path).resolve().is_relative_to(home.resolve()) for path, _ in rows), f"Synthetic log isolation failed (cached rows: {len(rows)})"
                initial_cache_size = max(size for _, size in rows)
                first = usage(process.pid)
                start = time.monotonic()
                footprints = [first["phys_footprint"]]
                samples = []
                target = logs / "rollout-000.jsonl"
                for i in range(seconds):
                    with target.open("a") as stream:
                        stream.write(line("event_msg", {"type": "agent_reasoning"}))
                        stream.write(line("event_msg", {"type": "token_count", "info": {
                            "total_token_usage": {"total_tokens": 301 + i}}}))
                    time.sleep(1)
                    assert process.poll() is None, "App exited during workload"
                    current = usage(process.pid)
                    footprints.append(current["phys_footprint"])
                    samples.append({"second": i + 1, "physical_footprint_bytes": current["phys_footprint"]})
                elapsed = time.monotonic() - start
                last = usage(process.pid)
                cpu_ns = last["user_time"] + last["system_time"] - first["user_time"] - first["system_time"]
                with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
                    final_cache_size = db.execute("SELECT MAX(size) FROM session_cache").fetchone()[0]
                assert final_cache_size > initial_cache_size, "App did not collect the appended workload"
                return {"workload_seconds": elapsed, "cpu_ms": cpu_ns / 1e6,
                    "verified_synthetic_session_rows": len(rows), "cache_grew_during_workload": True,
                    "cpu_percent_one_core": cpu_ns / (elapsed * 1e9) * 100,
                    "physical_footprint_start_bytes": footprints[0], "physical_footprint_end_bytes": footprints[-1],
                    "physical_footprint_max_sampled_bytes": max(footprints),
                    "package_idle_wakeups": last["pkg_idle_wkups"] - first["pkg_idle_wkups"],
                    "interrupt_wakeups": last["interrupt_wkups"] - first["interrupt_wkups"],
                    "disk_read_bytes": last["diskio_bytesread"] - first["diskio_bytesread"],
                    "disk_write_bytes": last["diskio_byteswritten"] - first["diskio_byteswritten"], "samples": samples}
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=pathlib.Path, required=True)
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--seconds", type=int, default=65)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    assert 35 <= args.seconds <= 180
    report = {"scope": "hidden app; 80 synthetic logs x 300 counters, one log appended each second; fresh processes",
              "battery_duration_measured": False, "baseline": run(args.baseline, args.seconds)}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    report["candidate"] = run(args.candidate, args.seconds)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: {key: value for key, value in result.items() if key != "samples"}
                      for k, result in report.items() if isinstance(result, dict)}, indent=2))


if __name__ == "__main__":
    main()
