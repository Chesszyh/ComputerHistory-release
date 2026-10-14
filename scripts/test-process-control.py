#!/usr/bin/env python3
"""Run against a built collector; all processes and output directories are test-owned."""
import fcntl
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/computer-history").resolve()


def command(root, *args):
    return subprocess.run([str(binary), *args, "--out", str(root)],
                          capture_output=True, text=True, timeout=8)


def wait_for_record(root, process, supervisor=False, previous_pid=None):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"collector exited: {process.returncode}")
        try:
            record = json.loads((root / "collector.pid").read_text())
            if (isinstance(record, dict) and record.get("pid") != previous_pid
                    and (supervisor or record.get("pid") == process.pid)):
                return record
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.02)
    raise AssertionError("collector did not publish identity")


with tempfile.TemporaryDirectory(prefix="collector-cli-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": False}))
    foreign = subprocess.Popen(["/bin/sleep", "60"])
    collector = None
    try:
        (root / "collector.pid").write_text(str(foreign.pid))
        assert command(root, "--stop").returncode == 0
        assert foreign.poll() is None, "legacy PID file signaled another program"
        print("PASS: legacy PID file cannot stop another program")

        collector = subprocess.Popen([str(binary), "collect", "--out", str(root)])
        record = wait_for_record(root, collector)
        duplicate = command(root, "collect", "--seconds", "0.1")
        assert duplicate.returncode == 73, "second collector acquired the output directory"
        assert json.loads((root / "collector.pid").read_text()) == record
        print("PASS: concurrent collector rejected without replacing identity")

        forged = dict(record, startedSeconds=record["startedSeconds"] + 1)
        (root / "collector.pid").write_text(json.dumps(forged))
        assert command(root, "--stop").returncode == 0
        assert collector.poll() is None, "mismatched start time received a signal"
        print("PASS: mismatched start time rejected while lock is held")
        (root / "collector.pid").write_text(json.dumps(record))

        status = command(root, "--status")
        assert "运行中" in status.stdout
        stopped = command(root, "--stop")
        assert stopped.returncode == 0, stopped.stderr
        assert collector.wait(timeout=5) == 0
        assert not (root / "collector.pid").exists()
        assert list((root / "segments").glob("*/metadata.json"))
        assert all(path.read_bytes() == b"" for path in (root / "segments").glob("*/events.jsonl")), \
            "disabled recording wrote events before its first control poll"
        print("PASS: verified collector respects startup pause, stops and seals metadata")

        collector = subprocess.Popen([str(binary), "collect", "--out", str(root)])
        wait_for_record(root, collector)
        time.sleep(0.2)
        collector.kill()
        collector.wait(timeout=5)
        originals = {path: path.read_bytes() for path in (root / "segments").glob("*/*")}
        collector = subprocess.Popen([str(binary), "collect", "--out", str(root)])
        wait_for_record(root, collector)
        time.sleep(0.2)
        assert command(root, "--stop").returncode == 0
        assert collector.wait(timeout=5) == 0
        assert all(path.read_bytes() == data for path, data in originals.items())
        print("PASS: restart after crash preserves every existing segment file")

        with (root / "collector.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            forged = dict(record, pid=foreign.pid)
            (root / "collector.pid").write_text(json.dumps(forged))
            assert command(root, "--stop").returncode == 0
            assert foreign.poll() is None
        print("PASS: foreign process identity rejected even with a held lock")
    finally:
        for process in (collector, foreign):
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix="collector-supervisor-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": False}))
    supervisor_script = Path(__file__).resolve().with_name("supervise.sh")
    environment = dict(os.environ, COMPUTER_HISTORY_BIN=str(binary))
    supervisors = []
    try:
        first = subprocess.Popen(["/bin/bash", str(supervisor_script), "--retry-delay", "0.2", "--no-model", "--out", str(root)],
                                 env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
        supervisors.append(first)
        record = wait_for_record(root, first, supervisor=True)
        second = subprocess.Popen(["/bin/bash", str(supervisor_script), "--retry-delay", "0.2", "--no-model", "--out", str(root)],
                                  env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True)
        supervisors.append(second)
        assert second.wait(timeout=3) == 0, "duplicate supervisor did not finish cleanly"
        assert command(root, "--stop").returncode == 0
        assert first.wait(timeout=5) == 0
        time.sleep(0.6)
        assert not (root / "collector.pid").exists(), "stopped collector was resurrected"
        assert "未运行" in command(root, "--status").stdout
        print("PASS: two supervisors cannot resurrect a stopped collector")

        first = subprocess.Popen(["/bin/bash", str(supervisor_script), "--retry-delay", "0.2", "--no-model", "--out", str(root)],
                                 env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
        supervisors.append(first)
        record = wait_for_record(root, first, supervisor=True)
        os.kill(record["pid"], signal.SIGKILL)
        replacement = wait_for_record(root, first, supervisor=True, previous_pid=record["pid"])
        assert replacement["pid"] != record["pid"]
        assert command(root, "--stop").returncode == 0
        assert first.wait(timeout=5) == 0
        time.sleep(0.6)
        assert not (root / "collector.pid").exists()
        print("PASS: supervisor retries a real crash and honors subsequent stop")
    finally:
        for process in supervisors:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix="collector-prune-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": False}))
    oldest = root / "segments" / "2020-01-01T00-00-00Z"
    next_oldest = root / "segments" / "2020-01-01T00-10-00Z"
    unknown = root / "segments" / "unrecognized-directory"
    for segment in (oldest, next_oldest, unknown):
        segment.mkdir(parents=True)
        (segment / "events.jsonl").write_text("test payload\n")
    (root / "config.json").write_text(json.dumps({"retention": {"maxTotalBytes": 1, "maxAgeDays": 1}}))
    oldest.chmod(0o500)
    try:
        if os.geteuid() == 0:
            raise AssertionError("permission-denial integration scenario requires a non-root user")
        result = command(root, "collect", "--seconds", "0.1")
        assert result.returncode == 0, result.stderr
        log = (root / "collector.log").read_text()
        assert "清理失败（删除目录）" in log and str(oldest) in log
        assert (oldest / "events.jsonl").read_text() == "test payload\n"
        assert not next_oldest.exists(), "removal failure prevented other cleanup"
        assert (unknown / "events.jsonl").read_text() == "test payload\n"
        print("PASS: cleanup failure is logged while other eligible segments are removed")
    finally:
        oldest.chmod(0o700)

with tempfile.TemporaryDirectory(prefix="collector-close-failure-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": False}))
    supervisor = subprocess.Popen([str(binary), "supervise", "--out", str(root),
                                   "--no-model", "--retry-delay", "0.1"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True)
    try:
        identity = wait_for_record(root, supervisor, supervisor=True)
        segment = next((root / "segments").iterdir())
        (segment / "metadata.json").mkdir()
        os.kill(identity["pid"], signal.SIGINT)
        assert supervisor.wait(timeout=8) == 74, "failed stop was treated as success or restarted"
        assert "封口失败" in (root / "collector.log").read_text()
        assert not (root / "collector.pid").exists()
        print("PASS: metadata failure exits with 74 and does not restart a stopped collector")
    finally:
        try:
            os.killpg(supervisor.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        supervisor.wait(timeout=5)

with tempfile.TemporaryDirectory(prefix="collector-invalid-config-") as directory:
    root = Path(directory)
    (root / "config.json").write_text('{"policy":{"blocklist":"invalid"}}')
    original = (root / "config.json").read_bytes()
    result = command(root, "collect", "--seconds", "0.1")
    assert result.returncode == 1 and "policy.blocklist" in result.stderr
    assert not (root / "segments").exists()
    assert (root / "config.json").read_bytes() == original
    print("PASS: invalid privacy configuration fails before collection without replacing the file")


# A loopback endpoint detects accidental model calls without sending data externally.
import http.server
import threading


class ModelProbe(http.server.BaseHTTPRequestHandler):
    requests = 0

    def do_POST(self):
        type(self).requests += 1
        self.send_response(500)
        self.end_headers()

    def log_message(self, *args):
        pass


with tempfile.TemporaryDirectory(prefix="collector-offline-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": True}))
    segment_id = "2020-01-01T00-00-00Z"
    segment = root / "segments" / segment_id
    segment.mkdir(parents=True)
    (root / "config.json").write_text(json.dumps({"retention": {"maxAgeDays": 0}}))
    (segment / "metadata.json").write_text(json.dumps({"suppressedEventCount": 0}))
    (segment / "events.jsonl").write_text(json.dumps({
        "id": 1, "timestamp": "2020-01-01T00:00:01Z", "kind": "window.changed",
        "app": {"name": "Example Editor", "bundleIdentifier": "test.editor"},
        "window": {"title": "Synthetic document"}
    }) + "\n")
    server = http.server.HTTPServer(("127.0.0.1", 0), ModelProbe)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = dict(os.environ, DEEPSEEK_API_KEY="synthetic-test-key",
                       DEEPSEEK_BASE_URL=f"http://127.0.0.1:{server.server_port}")
    with (root / "supervisor-test.log").open("w") as log:
        supervisor = subprocess.Popen([str(binary), "supervise", "--out", str(root),
                                       "--no-model", "--memorize-interval", "0.1"],
                                      env=environment, stdout=log, stderr=log,
                                      start_new_session=True)
        try:
            wait_for_record(root, supervisor, supervisor=True)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if "生成任务完成：叙述层" in (root / "supervisor-test.log").read_text():
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("offline generation cycle did not complete")
            assert list((root / "memories").glob("*-10min-memory-summary.md"))
            assert ModelProbe.requests == 0, "--no-model allowed an HTTP request"
            rewritten = command(root, "memorize", "--segment", segment_id, "--overwrite", "--no-model")
            assert rewritten.returncode == 0, rewritten.stderr
            assert command(root, "verify").returncode == 0, "rewriting a segment introduced a self-reference"
            print("PASS: single-segment overwrite keeps the memory chain valid")
            assert command(root, "--stop").returncode == 0
            assert supervisor.wait(timeout=5) == 0
            print("PASS: supervisor --no-model generates synthetic memories without HTTP requests")
        finally:
            try:
                os.killpg(supervisor.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            supervisor.wait(timeout=5)
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
