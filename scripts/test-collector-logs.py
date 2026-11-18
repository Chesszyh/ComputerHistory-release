#!/usr/bin/env python3
"""Check collector.log using owned background processes and numbered synthetic lines."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PROBE = '''
import ComputerHistoryCore
import Foundation

let log = CollectorLog(url: URL(fileURLWithPath: CommandLine.arguments[2]))
if CommandLine.arguments[1] == "trim" {
    if !CollectorSupervisor.enforceLogBound(at: log.url, maxBytes: 8192) { exit(2) }
} else {
    try CollectorLogCapture.shared.redirect(to: log)
    for i in 100..<112 {
        let line = String(format: "event %06d %@", i, String(repeating: "x", count: 111))
        if i.isMultiple(of: 2) { print(line) }
        else { FileHandle.standardError.write(Data((line + "\\n").utf8)) }
    }
    try Data().write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
}
'''

TRUNCATE_WINDOW = r'''
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

static int pausedTruncate(int fd, off_t length) {
    const char *ready = getenv("HISTORY_LOG_CUTOFF_READY");
    const char *resume = getenv("HISTORY_LOG_CUTOFF_RESUME");
    int marker = open(ready, O_WRONLY | O_CREAT, 0600);
    if (marker >= 0) close(marker);
    for (int step = 0; step < 500 && access(resume, F_OK) != 0; ++step) usleep(10000);
    return ftruncate(fd, length);
}

__attribute__((used, section("__DATA,__interpose")))
static const void *const hook[] = {(const void *)pausedTruncate, (const void *)ftruncate};
'''


def sign(path, identifier):
    signer = shutil.which("local-codesign")
    args = [signer, "--identifier", identifier] if signer else ["codesign", "--force", "--sign", "-", "--identifier", identifier]
    subprocess.run([*args, path], check=True, stdout=subprocess.DEVNULL)


def wait_for(predicate, message):
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError(message)


def seeded_rows():
    return ''.join(f'event {idx:06d} {"x" * 111}\n' for idx in range(100))


def verify_retention(temp, binary):
    probe, dylib = temp / "probe", temp / "window.dylib"
    source, shim = temp / "probe.swift", temp / "window.c"
    source.write_text(PROBE)
    shim.write_text(TRUNCATE_WINDOW)
    subprocess.run(["xcrun", "swiftc", "-I", binary.parent, source,
                    binary.parent / "ComputerHistoryCore.o", "-o", probe], check=True)
    subprocess.run(["xcrun", "clang", "-dynamiclib", shim, "-o", dylib], check=True)
    sign(probe, "xyz.chesszyh.computer-history.log-test")
    sign(dylib, "xyz.chesszyh.computer-history.log-test-window")
    log, ready, resume, wrote = [temp / name for name in ("bounded.log", "ready", "resume", "wrote")]
    log.write_text(seeded_rows())
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(dylib), HISTORY_LOG_CUTOFF_READY=str(ready),
               HISTORY_LOG_CUTOFF_RESUME=str(resume))
    processes = []
    try:
        cutter = subprocess.Popen([probe, "trim", log], env=env)
        processes.append(cutter)
        wait_for(ready.exists, "production trim did not reach its truncate boundary")
        writer = subprocess.Popen([probe, "write", log, wrote])
        processes.append(writer)
        wait_for(wrote.exists, "concurrent writer did not send the numbered lines")
        assert writer.poll() is None, "writer exited while the trimmer still owned the log lock"
        resume.touch()
        assert cutter.wait(timeout=4) == writer.wait(timeout=4) == 0
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=4)
    lines = log.read_text().splitlines()
    indices = [int(line.split()[1]) for line in lines]
    assert indices[0] > 0 and indices[-1] == 111 and indices == list(range(indices[0], 112)), indices
    assert all(line == f'event {idx:06d} {"x" * 111}' for idx, line in zip(indices, lines))
    assert log.stat().st_size <= 8192
    print(f"PASS: trim evicted 0–{indices[0] - 1}; retained a complete tail through 111, including all concurrent appends")


def verify_supervisor_mode(temp, binary, mode):
    root = temp / mode
    root.mkdir()
    log = root / "collector.log"
    seed = seeded_rows()
    log.write_text(seed)
    control = root / "control.json"
    control.write_text(json.dumps({"recording": False, "summarizing": False}))
    (root / "config.json").write_text(json.dumps({"maxLogBytes": 8192}))
    env = dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS="0")
    command = [binary, "supervise", "--out", root, "--no-model", "--memorize-interval", "0"]
    terminal_log = root / "terminal.out"
    supervisor = None
    target = log if mode in ("detached", "launchd-stdio") else terminal_log
    backup = root / "collector.log.1"
    try:
        if mode == "detached":
            started = subprocess.run(command + ["--daemon"], env=env, capture_output=True, timeout=10)
            assert started.returncode == 0, started.stderr
        else:
            with target.open("ab", buffering=0) as output:
                supervisor = subprocess.Popen(command, env=env, stdout=output, stderr=output)
        wait_for(lambda: (root / "collector.pid").exists(), f"{mode} did not start a collector")
        wait_for(lambda: log.exists() and log.stat().st_size <= 8192, f"{mode} did not bound the active log")
        wait_for(lambda: "采集器已启动" in target.read_text(), f"{mode} did not log to the expected stream")
        if mode == "detached":
            assert backup.read_text() == seed
        else:
            assert not backup.exists() and "event 000099" in log.read_text()
        pending = control.with_suffix(".new")
        pending.write_text(json.dumps({"recording": False, "summarizing": True, "flushRequested": True}))
        pending.replace(control)
        wait_for(lambda: "没有需要生成的段" in target.read_text(), f"{mode} worker did not write to the visible log after trimming")
        stopped = subprocess.run([binary, "--stop", "--out", root], capture_output=True, timeout=13)
        assert stopped.returncode == 0, stopped.stderr
        if supervisor is not None:
            assert supervisor.wait(timeout=4) == 0
        assert "已停止。写入" in log.read_text(), f"{mode} lost the collector's final log line"
        assert log.stat().st_size <= 8192
        if mode == "detached":
            assert backup.read_text() == seed, "detached child wrote into the rotated log"
        print(f"PASS: {mode} supervisor, worker, and collector output remains visible after bounding")
    finally:
        subprocess.run([binary, "--stop", "--out", root], capture_output=True, timeout=13)
        if supervisor is not None and supervisor.poll() is None:
            supervisor.kill()
            supervisor.wait(timeout=4)


def verify_invalid_config_restart(temp, binary, managed):
    root = temp / ('managed-config-error' if managed else 'terminal-config-error')
    root.mkdir()
    config = root / 'config.json'
    config.write_text('{}')
    (root / 'control.json').write_text('{"recording": false, "summarizing": false}')
    output = root / ('collector.log' if managed else 'terminal.out')
    collector_pid = root / 'collector.pid'
    env = dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0')
    command = [binary, 'supervise', '--out', root, '--no-model', '--retry-delay', '0.05']
    with output.open('ab', buffering=0) as log:
        supervisor = subprocess.Popen(command, env=env, stdout=log, stderr=log)
    try:
        wait_for(collector_pid.exists, 'supervisor did not start its own collector')
        child = json.loads(collector_pid.read_bytes())['pid']
        assert int(subprocess.check_output(['/bin/ps', '-o', 'ppid=', '-p', str(child)]).strip()) == supervisor.pid
        config.write_text('{invalid configuration')
        os.kill(child, signal.SIGKILL)
        messages = [f'无法读取配置 {path}：' for path in (config, config.resolve())]
        def has_diagnostic():
            log = output.read_text(errors='replace')
            return any(message in log for message in messages)
        wait_for(has_diagnostic, f'{root.name} lost the invalid config diagnostic')
        print(f"PASS: invalid config on restart reaches {'managed log' if managed else 'foreground stderr'}")
    finally:
        subprocess.run([binary, '--stop', '--out', root], capture_output=True, timeout=13)
        if supervisor.poll() is None:
            supervisor.kill()
        supervisor.wait(timeout=4)


def main(binary):
    with tempfile.TemporaryDirectory(prefix="history-log-test-") as directory:
        temp = Path(directory)
        verify_retention(temp, binary)
        for mode in ("foreground", "detached", "launchd-stdio"):
            verify_supervisor_mode(temp, binary, mode)
        for managed in (False, True):
            verify_invalid_config_restart(temp, binary, managed)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
