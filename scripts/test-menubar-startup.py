#!/usr/bin/env python3
"""Verify menu-bar startup order without starting a graphical scene."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

# Configuring AX is the first effect of StatusModel. Exit there in the successful launch
# case before SwiftUI can start the menu, open any permissions UI, or change focus.
MARK_MODEL = r'''
#include <ApplicationServices/ApplicationServices.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

static AXError markModel(AXUIElementRef element, float timeout) {
    const char *marker = getenv("HISTORY_TEST_MENUBAR_MODEL");
    if (marker) {
        int fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd >= 0) close(fd);
        _exit(fd < 0 ? 91 : 0);
    }
    return AXUIElementSetMessagingTimeout(element, timeout);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { AXError (*replace)(AXUIElementRef, float); AXError (*original)(AXUIElementRef, float); }
interpose = {markModel, AXUIElementSetMessagingTimeout};
'''
HOLD_LEASE = '''
import Foundation
import ComputerHistoryCore

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let lease = try CollectorProcessLease(root: root)
try lease.publish()
withExtendedLifetime(lease) { while true { _ = pause() } }
'''


def sign(path, identifier):
    signer = shutil.which("local-codesign")
    command = [signer, "--identifier", identifier] if signer else ["codesign", "--force", "--sign", "-", "--identifier", identifier]
    subprocess.run([*command, path], check=True, stdout=subprocess.DEVNULL)


def main(binary):
    with tempfile.TemporaryDirectory(prefix="history-menu-startup-") as directory:
        temp = Path(directory)
        interposer = temp / "model.dylib"
        (temp / "model.c").write_text(MARK_MODEL)
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-framework", "ApplicationServices",
                        temp / "model.c", "-o", interposer], check=True)
        sign(interposer, "xyz.chesszyh.computer-history.menu-test-probe")
        holder = temp / "computer-history-menubar"
        (temp / "holder.swift").write_text(HOLD_LEASE)
        subprocess.run(["xcrun", "swiftc", "-I", binary.parent, temp / "holder.swift",
                        binary.parent / "ComputerHistoryCore.o", "-o", holder], check=True)
        sign(holder, "xyz.chesszyh.computer-history.menu-test-holder")
        marker = temp / "model-initialized"
        root = temp / "data"
        root.mkdir()
        lease = root / ".menubar"
        pid_file = lease / "collector.pid"
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(interposer), HISTORY_TEST_MENUBAR_MODEL=str(marker))

        def run(*args):
            return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=8)

        invalid = run("--out")
        assert invalid.returncode == 2 and not marker.exists(), invalid
        absent = run("--out", root, "--stop")
        assert not marker.exists(), "--stop initialized StatusModel in an empty directory"
        assert absent.returncode == 0 and "未找到" in absent.stdout and not lease.exists(), absent

        with subprocess.Popen([holder, lease]) as active:
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and active.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                identity = json.loads(pid_file.read_bytes())
                assert identity["pid"] == active.pid
                duplicate = run("--out", root)
                assert not marker.exists(), "duplicate startup initialized StatusModel"
                assert duplicate.returncode == 0 and "已在运行" in duplicate.stdout, duplicate
                assert json.loads(pid_file.read_bytes()) == identity and active.poll() is None
                stop = run("--out", root, "--stop")
                assert not marker.exists(), "--stop initialized StatusModel while stopping a live instance"
                assert stop.returncode == 0 and "已停止" in stop.stdout, stop
                assert active.wait(timeout=3) == -15
            finally:
                if active.poll() is None:
                    active.kill()
                    active.wait(timeout=3)

        with subprocess.Popen([binary, "--out", root], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as new:
            try:
                assert new.wait(timeout=8) == 0, new.communicate()
                assert marker.exists(), "normal startup did not reach StatusModel initialization"
                assert json.loads(pid_file.read_bytes())["pid"] == new.pid, "normal startup did not publish its identity first"
            finally:
                if new.poll() is None:
                    new.kill()
                    new.wait(timeout=3)
        print("PASS: stop and duplicate startup skip StatusModel; normal startup publishes its identity first")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
