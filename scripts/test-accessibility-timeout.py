#!/usr/bin/env python3
"""Measure AX against a test-owned AppKit window. No activity contents are printed."""
import argparse
import gzip
import json
import os
import plistlib
import shutil
from pathlib import Path
import signal
import subprocess
import tempfile
import time

QUERIES = ("raw", "window", "focus", "activation", "tree")


def wait_until(predicate, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.01)
    raise AssertionError("synthetic fixture did not reach its expected state")


def probe(exe, operation, pid, preset, deadline, marker=None):
    with subprocess.Popen([exe, operation, str(pid), preset], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True) as process:
        try:
            if marker is not None:
                wait_until(lambda: marker.exists() or process.poll() is not None, timeout=5)
                assert marker.exists(), "tree traversal did not reach the fixture's blocking node"
            try:
                stdout, stderr = process.communicate(timeout=deadline)
            except subprocess.TimeoutExpired:
                return {"atLeastMs": deadline * 1000}
            assert process.returncode == 0, stderr or stdout
            return json.loads(stdout)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)


def measure(exe, presets, budget_limit, expect_bounded):
    original = subprocess.check_output([exe, "active"], text=True, timeout=5).strip()
    rows = []
    with tempfile.TemporaryDirectory(prefix="history-ax-fixture-") as directory:
        gate = Path(directory) / "gate"
        ready, arm, tripped = [gate.with_suffix(x) for x in (".ready", ".arm", ".tripped")]
        with subprocess.Popen([exe, "fixture", str(gate)], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, start_new_session=True) as fixture:
            try:
                wait_until(lambda: ready.exists() or fixture.poll() is not None)
                assert fixture.poll() is None, "AppKit fixture exited before displaying its window"
                pid = fixture.pid
                def record(state, preset, query, result):
                    row = dict(state=state, preset=preset, query=query, **result)
                    rows.append(row)
                    print(json.dumps(row), flush=True)

                def assert_normal(query, result):
                    if query == "raw":
                        assert result.get("status") == 0, result
                    if query == "window":
                        assert result.get("expectedTitle"), result
                    if query == "focus":
                        assert result.get("expectedValue"), result
                    if query == "tree":
                        assert result.get("expectedBody"), result

                for preset in presets:
                    for query in QUERIES:
                        result = probe(exe, query, pid, preset, 5)
                        assert_normal(query, result)
                        record("responsive", preset, query, result)
                    for query in QUERIES:
                        fixture.send_signal(signal.SIGSTOP)
                        try:
                            time.sleep(.03)
                            result = probe(exe, query, pid, preset, budget_limit)
                            record("stopped", preset, query, result)
                            if expect_bounded:
                                assert result.get("ms", 10_000) < 1800, result
                                if query == "raw":
                                    assert result["status"] == -25204, result
                                if query == "window":
                                    assert not result["expectedTitle"], result
                                if query == "focus":
                                    assert not result["expectedValue"], result
                                if query == "tree":
                                    assert result["roots"] == 0, result
                        finally:
                            fixture.send_signal(signal.SIGCONT)
                        time.sleep(.06)

                    tripped.unlink(missing_ok=True)
                    arm.touch()
                    try:
                        result = probe(exe, "tree", pid, preset, budget_limit, marker=tripped)
                        record("stopped mid-tree", preset, "tree", result)
                        if expect_bounded:
                            assert result.get("ms", 10_000) < 1800 and result["roots"] == 0, result
                    finally:
                        fixture.send_signal(signal.SIGCONT)
                    for query in ("window", "focus", "tree"):
                        result = probe(exe, query, pid, preset, 5)
                        assert_normal(query, result)
                        record("resumed", preset, query, result)
            finally:
                if fixture.poll() is None:
                    fixture.kill()
                fixture.wait(timeout=4)
                if original not in ("", "0"):
                    subprocess.run([exe, "activate", original], check=False, timeout=4)
    return rows


def fixture_bundle(exe, parent):
    contents = parent / "SyntheticAX.app" / "Contents"
    executable = contents / "MacOS" / "synthetic-ax"
    executable.parent.mkdir(parents=True)
    shutil.copy2(exe, executable)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "test.ax.timeout",
        "CFBundleName": "Synthetic AX fixture",
        "CFBundleExecutable": executable.name,
        "CFBundlePackageType": "APPL",
    }))
    return executable


def measure_running_apps(exe, collector_exe, interposer):
    original = subprocess.check_output([exe, "active"], text=True, timeout=5).strip()
    with tempfile.TemporaryDirectory(prefix="history-ax-runtime-") as directory:
        parent = Path(directory)
        gate = parent / "gate"
        root = parent / "history"
        root.mkdir()
        (root / "control.json").write_text(json.dumps({"recording": True, "summarizing": False}))
        (root / "config.json").write_text(json.dumps({"policy": {
            "defaultApplicationBehavior": "do_not_observe",
            "allowlist": [{"scope": "app", "bundleID": "test.ax.timeout"}],
        }}))
        fixture = subprocess.Popen([fixture_bundle(exe, parent), "fixture", gate], start_new_session=True)
        collector = menu = None
        try:
            wait_until(lambda: gate.with_suffix(".ready").exists())
            def has_focus():
                if subprocess.check_output([exe, "active"], text=True, timeout=5).strip() == str(fixture.pid):
                    return True
                subprocess.run([exe, "activate", str(fixture.pid)], check=True, timeout=4)
                return False

            wait_until(has_focus)
            arm, entered, returned = [gate.with_suffix(x) for x in (".observe", ".entered", ".returned")]
            env = dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS="0",
                       DYLD_INSERT_LIBRARIES=str(interposer), HISTORY_AX_TEST_PID=str(fixture.pid),
                       HISTORY_AX_TEST_ARM=str(arm), HISTORY_AX_TEST_ENTERED=str(entered),
                       HISTORY_AX_TEST_RETURNED=str(returned))
            collector = subprocess.Popen([collector_exe, "collect", "--out", root], env=env)
            menu = subprocess.Popen([exe, "watch-menu", root, str(fixture.pid)])

            def snapshots():
                count = 0
                for segment in (root / "segments").glob("*"):
                    try:
                        data = (segment / "events.jsonl").read_bytes()
                    except FileNotFoundError:
                        try:
                            data = gzip.decompress((segment / "events.jsonl.gz").read_bytes())
                        except FileNotFoundError:
                            continue
                    for line in data.splitlines(keepends=True):
                        if not line.endswith(b"\n"):
                            continue
                        event = json.loads(line)
                        if event.get("kind") == "window.changed":
                            assert event["app"]["bundleIdentifier"] == "test.ax.timeout"
                            assert event["window"]["title"] == "Synthetic AX timeout fixture"
                            tree = event.get("ax") or {}
                            if tree.get("mode") == "fullTree" and "SYNTHETIC AX BODY" in tree["text"]:
                                count += 1
                return count

            try:
                wait_until(lambda: (root / "menu-ready").exists() and snapshots() >= 1, timeout=12)
            except AssertionError as error:
                log = root / "collector.log"
                text = log.read_text() if log.exists() else ""
                raise AssertionError(f"collector frames: {snapshots()}, collector exit: {collector.poll()}, "
                                     f"menu ready: {(root / 'menu-ready').exists()}, "
                                     f"collector permission warning: {'未授予辅助功能权限' in text}, "
                                     f"fixture frontmost: {has_focus()}") from error
            before = snapshots()
            fixture.send_signal(signal.SIGSTOP)
            arm.touch()
            wait_until(returned.exists)
            wait_until(lambda: (root / "menu-unavailable").exists() or menu.poll() is not None, timeout=10)
            assert (root / "menu-unavailable").exists(), "menu did not publish an unavailable window"
            fixture.send_signal(signal.SIGCONT)
            wait_until(has_focus)
            try:
                wait_until(lambda: snapshots() > before and (root / "menu-recovered").exists(), timeout=10)
            except AssertionError as error:
                raise AssertionError(f"collector frames {before} → {snapshots()}, "
                                     f"menu recovered: {(root / 'menu-recovered').exists()}") from error
            assert menu.wait(timeout=4) == 0
            print("PASS: the running collector and menu recovered after the fixture resumed", flush=True)

            entered.unlink()
            returned.unlink()
            fixture.send_signal(signal.SIGSTOP)
            arm.touch()
            wait_until(entered.exists)
            assert not returned.exists(), "AX query completed before --stop was sent"
            start = time.monotonic()
            stop = subprocess.run([collector_exe, "--stop", "--out", root], capture_output=True, timeout=5)
            elapsed = (time.monotonic() - start) * 1000
            assert stop.returncode == 0, stop.stderr.decode(errors="replace")
            assert collector.wait(timeout=3) == 0
            assert returned.exists() and elapsed < 1800, elapsed
            assert not (root / "collector.pid").exists()
            assert any(json.loads(path.read_bytes()).get("endReason") == "stopped"
                       for path in (root / "segments").glob("*/metadata.json"))
            print(f"PASS: --stop during synchronous AX query sealed the segment in {elapsed:.0f} ms", flush=True)
        finally:
            for process in (menu, collector, fixture):
                if process is not None:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=4)
            if original not in ("", "0"):
                subprocess.run([exe, "activate", original], check=False, timeout=4)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--foreground", action="store_true", help="allow the synthetic window to become frontmost")
    parser.add_argument("--presets", nargs="+", default=["collector", "menubar"])
    parser.add_argument("--limit", type=float, default=16)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--collector", type=Path)
    parser.add_argument("--interposer", type=Path)
    args = parser.parse_args()
    if not args.foreground:
        parser.error("this native window test needs explicit --foreground; use swift test for background regressions")
    if (args.collector is None) != (args.interposer is None):
        parser.error("--collector and --interposer must be supplied together")
    exe = args.executable.resolve()
    permissions = subprocess.run([exe, "permission"], timeout=5)
    if permissions.returncode:
        raise SystemExit(permissions.returncode)
    rows = measure(exe, args.presets, args.limit, not args.baseline)
    if args.output:
        args.output.write_text(json.dumps(rows, indent=2) + "\n")
    print("PASS: synthetic AX measurements and recovery")
    if args.collector:
        measure_running_apps(exe, args.collector.resolve(), args.interposer.resolve())
