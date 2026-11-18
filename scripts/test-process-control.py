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

os.environ["COMPUTER_HISTORY_NOTIFICATIONS"] = "0"

binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/computer-history").resolve()


def command(root, *args):
    return subprocess.run([str(binary), *args, "--out", str(root)],
                          capture_output=True, text=True, timeout=13)


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
        assert command(root, "--stop").returncode == 1
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
            assert command(root, "--stop").returncode == 1
            assert foreign.poll() is None
        print("PASS: foreign process identity rejected even with a held lock")
    finally:
        for process in (collector, foreign):
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)


def wait_until(predicate, message, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(message)


def pid_is_gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def collector_lock_is_held(root):
    try:
        with (root / "collector.lock").open("rb") as lease:
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
    except FileNotFoundError:
        pass
    return False


for startup in ("publishes", "times out", "exits"):
    with tempfile.TemporaryDirectory(prefix="collector-stop-starting-") as directory:
        root = Path(directory)
        (root / "control.json").write_text('{"recording": false, "summarizing": false}')
        log = root / "collector.log"
        # Opening the log for writing gates a real collect after flock and before identity publication.
        os.mkfifo(log)
        with subprocess.Popen([str(binary), "collect", "--out", str(root)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as collector:
            stop = None
            reader = None
            try:
                wait_until(lambda: collector_lock_is_held(root), "collector never acquired startup lock")
                assert not (root / "collector.pid").exists()
                stop = subprocess.Popen([str(binary), "--stop", "--out", str(root)],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if startup == "times out":
                    _, error = stop.communicate(timeout=4)
                    assert stop.returncode == 1 and "身份尚未就绪" in error, error
                    assert collector.poll() is None and not (root / "collector.pid").exists()
                    reader = os.open(log, os.O_RDONLY | os.O_NONBLOCK)
                    wait_for_record(root, collector)
                    assert command(root, "--stop").returncode == 0
                else:
                    time.sleep(0.15)
                    assert stop.poll() is None, "--stop returned while the collector was starting"
                    if startup == "publishes":
                        reader = os.open(log, os.O_RDONLY | os.O_NONBLOCK)
                    else:
                        collector.kill()
                        collector.wait(timeout=5)
                    stdout, error = stop.communicate(timeout=5)
                    assert stop.returncode == 0, error
                    if startup == "publishes":
                        assert "已停止" in stdout and list((root / "segments").glob("*/metadata.json"))
                    else:
                        assert "未找到" in stdout
                assert collector.wait(timeout=5) == (0 if startup != "exits" else -signal.SIGKILL)
                assert not (root / "collector.pid").exists()
                print(f"PASS: --stop handles an independent collector that {startup} before startup resolves")
            finally:
                for process in (stop, collector):
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                if reader is not None:
                    os.close(reader)


def supervisor_process(root, retry_delay, **options):
    return subprocess.Popen(
        [str(binary), "supervise", "--out", str(root), "--no-model",
         "--retry-delay", str(retry_delay), "--memorize-interval", "0"],
        start_new_session=True, **options)


def clean_process_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix="collector-stop-backoff-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": False}))
    log = root / "test.log"
    with log.open("w") as output:
        supervisor = supervisor_process(root, retry_delay=10, stdout=output, stderr=output)
        try:
            collector = wait_for_record(root, supervisor, supervisor=True)
            os.kill(collector["pid"], signal.SIGKILL)
            wait_until(lambda: "秒后重启" in log.read_text(), "supervisor never entered restart backoff")
            duplicate = supervisor_process(root, retry_delay=10, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, _ = duplicate.communicate(timeout=3)
                assert duplicate.returncode == 0 and "已有监督实例" in stdout.decode()
            finally:
                clean_process_group(duplicate)
            assert pid_is_gone(collector["pid"])
            stopped = command(root, "--stop")
            assert stopped.returncode == 0, stopped.stderr
            assert supervisor.wait(timeout=3) == 0, "supervisor did not stop during backoff"
            assert "已重启" not in log.read_text()
            print("PASS: restart backoff remains exclusive and can be stopped")
        finally:
            clean_process_group(supervisor)


with tempfile.TemporaryDirectory(prefix="collector-term-") as directory:
    root = Path(directory)
    (root / "control.json").write_text('{"recording": false, "summarizing": false}')
    for supervised in (False, True):
        process = (supervisor_process(root, retry_delay=10) if supervised else
                   subprocess.Popen([str(binary), "collect", "--out", str(root)], start_new_session=True))
        try:
            wait_for_record(root, process, supervisor=supervised)
            process.terminate()
            assert process.wait(timeout=5) == 0
            assert not (root / "collector.pid").exists()
            assert not (root / "supervisor.pid").exists()
        finally:
            clean_process_group(process)
    assert len(list((root / "segments").glob("*/metadata.json"))) == 2
    print("PASS: SIGTERM seals both standalone and supervised collection")


with tempfile.TemporaryDirectory(prefix="collector-detach-") as directory:
    root = Path(directory)
    (root / "control.json").write_text('{"recording": false, "summarizing": false}')
    started = command(root, "supervise", "--daemon", "--no-model")
    assert started.returncode == 0, started.stderr
    try:
        assert (root / "supervisor.pid").exists(), "daemon reported success before publishing identity"
        stopped = command(root, "--stop")
        assert stopped.returncode == 0, stopped.stderr
        assert not (root / "supervisor.pid").exists()
        assert not (root / "collector.pid").exists()
    finally:
        command(root, "--stop")
    print("PASS: daemon can be stopped immediately after startup")


with tempfile.TemporaryDirectory(prefix="collector-parent-killed-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": False}))
    supervisor = supervisor_process(root, retry_delay=0.2, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        collector = wait_for_record(root, supervisor, supervisor=True)
        supervisor.kill()
        assert supervisor.wait(timeout=3) == -signal.SIGKILL
        wait_until(lambda: pid_is_gone(collector["pid"]), "collector survived its supervisor")
        assert list((root / "segments").glob("*/metadata.json")), "collector did not seal on parent loss"
        assert not (root / "collector.pid").exists()
        print("PASS: collector seals and exits after supervisor SIGKILL")
    finally:
        clean_process_group(supervisor)


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
        wait_for_record(root, supervisor, supervisor=True)
        segment = next((root / "segments").iterdir())
        (segment / "metadata.json").mkdir()
        stopped = command(root, "--stop")
        assert stopped.returncode == 74, stopped.stderr
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


def seed_segment(root):
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
    return segment_id


with tempfile.TemporaryDirectory(prefix="collector-offline-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": True}))
    segment_id = seed_segment(root)
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
                if "生成任务完成：GitHub 私有备份" in (root / "supervisor-test.log").read_text():
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("offline generation cycle did not complete")
            assert list((root / "memories").glob("*-10min-memory-summary.md"))
            assert not list((root / "memories").glob("*-6h-memory-summary.md")), "six-hour summaries must not be scheduled"
            assert list((root / "reports" / "daily").glob("*.json")), "offline daily report was not generated"
            assert list((root / "reports" / "weekly").glob("*.json")), "offline weekly report was not generated"
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

class WaitingModel(ModelProbe):
    started = threading.Event()
    release = threading.Event()

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.started.set()
        self.release.wait(timeout=15)


with tempfile.TemporaryDirectory(prefix="collector-generation-parent-killed-") as directory:
    root = Path(directory)
    (root / "control.json").write_text('{"recording": false, "summarizing": true}')
    seed_segment(root)
    server = http.server.HTTPServer(("127.0.0.1", 0), WaitingModel)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (root / "model.json").write_text(json.dumps({
        "baseURL": f"http://127.0.0.1:{server.server_port}/v1",
        "model": "synthetic", "requiresAPIKey": False
    }))
    supervisor = subprocess.Popen([str(binary), "supervise", "--out", str(root)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True)
    try:
        collector = wait_for_record(root, supervisor, supervisor=True)
        assert WaitingModel.started.wait(timeout=8), "synthetic model request never started"
        worker = int((root / ".locks" / "memorize.lock").read_text().split()[1])
        supervisor.kill()
        assert supervisor.wait(timeout=3) == -signal.SIGKILL
        assert not WaitingModel.release.is_set()
        for pid in (collector["pid"], worker):
            wait_until(lambda: pid_is_gone(pid), f"supervised process {pid} survived a blocked request")
        print("PASS: parent loss stops a generation worker with a blocked model request")
    finally:
        clean_process_group(supervisor)
        WaitingModel.release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


for stopping in ("--stop", "SIGKILL"):
    with tempfile.TemporaryDirectory(prefix="collector-backup-stopped-") as directory:
        root = Path(directory)
        (root / "control.json").write_text('{"recording": false, "summarizing": true, "flushRequested": true}')
        (root / "backup.json").write_text('{"repository": "synthetic/private", "enabled": true}')
        helper = root / "gh"
        helper.write_text(
            '#!/bin/sh\n'
            'printf "synthetic stdout\\n"\n'
            'printf "synthetic stderr\\n" >&2\n'
            '/bin/sleep 60 &\n'
            f'printf "%s %s %s\\n" "$PPID" "$$" "$!" > "{root / "helper.pids"}"\n'
            'wait\n'
        )
        helper.chmod(0o700)
        log = root / "test.log"
        pids = []
        output_paths = set()
        with log.open("w") as output:
            supervisor = supervisor_process(root, retry_delay=0.2, stdout=output, stderr=output,
                                            env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}"))
            try:
                collector = wait_for_record(root, supervisor, supervisor=True)
                pid_file = root / "helper.pids"
                wait_until(lambda: pid_file.exists() and len(pid_file.read_text().split()) == 3,
                           "supervised backup never launched its helper", timeout=15)
                pids = [int(pid) for pid in pid_file.read_text().split()]
                assert all(not pid_is_gone(pid) for pid in pids)
                files = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pids[1]), "-d", "1,2", "-Ffn"],
                                       check=True, capture_output=True, text=True, timeout=5).stdout
                assert {"f1", "f2"} <= set(files.splitlines()), "helper output descriptors were not observed"
                for line in files.splitlines():
                    if line.startswith("n/"):
                        path = Path(line[1:])
                        if path.parent.resolve() == Path(tempfile.gettempdir()).resolve():
                            output_paths.add(path)
                if stopping == "SIGKILL":
                    supervisor.kill()
                    assert supervisor.wait(timeout=3) == -signal.SIGKILL
                else:
                    stopped = command(root, "--stop")
                    assert stopped.returncode == 0, stopped.stderr
                    assert supervisor.wait(timeout=3) == 0
                for pid in [collector["pid"], *pids]:
                    wait_until(lambda: pid_is_gone(pid), f"process {pid} survived supervisor stop")
                assert list((root / "segments").glob("*/metadata.json"))
                assert not any(path.exists() for path in output_paths), "backup helper left output on disk"
                print(f"PASS: {stopping} closes the backup, its helper process group, and its output")
            except AssertionError:
                print(log.read_text()[-2500:], file=sys.stderr)
                raise
            finally:
                clean_process_group(supervisor)
                for pid in pids:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                for path in output_paths:
                    path.unlink(missing_ok=True)

with tempfile.TemporaryDirectory(prefix="collector-reconfigure-") as directory:
    root = Path(directory)
    (root / "control.json").write_text(json.dumps({"recording": False, "summarizing": False}))
    config_path = root / "config.json"
    config_path.write_text("{}")
    log_path = root / "test.log"
    with log_path.open("w") as output:
        collector = subprocess.Popen([str(binary), "collect", "--out", str(root)], stdout=output, stderr=output)
        try:
            wait_for_record(root, collector)
            def wait_for_log(text, count=1):
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    assert collector.poll() is None, "configuration reload stopped the collector"
                    if (root / "collector.log").read_text().count(text) >= count:
                        return
                    time.sleep(0.05)
                raise AssertionError(f"missing reconfiguration log: {text}")
            updated = {"policy": {"blocklist": [{"scope": "app", "bundleID": "synthetic.blocked"}]}}
            config_path.write_text(json.dumps(updated))
            wait_for_log("采集配置已更新")
            config_path.write_text('{"policy":{"blocklist":false}}')
            wait_for_log("继续使用上次有效设置")
            config_path.write_text(json.dumps(updated))
            wait_for_log("采集配置已更新", 2)
            assert command(root, "--stop").returncode == 0
            assert collector.wait(timeout=5) == 0
            assert all(path.read_bytes() == b"" for path in (root / "segments").glob("*/events.jsonl"))
            print("PASS: live configuration reload, invalid-file rejection, recovery, and pause preservation")
        finally:
            if collector.poll() is None:
                collector.kill()
                collector.wait(timeout=5)
