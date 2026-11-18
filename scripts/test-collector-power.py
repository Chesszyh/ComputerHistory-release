#!/usr/bin/env python3
"""Drive the collector's IOKit callback without changing host power or foreground UI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

SHIM = r'''
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdlib.h>
#include <unistd.h>

static IOServiceInterestCallback callback;
static void *context;
static IONotificationPortRef powerPort;
static dispatch_source_t timer;
static const long testToken = 0x436850;

static void touch(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT, 0600);
    if (fd >= 0) close(fd);
}

static io_connect_t captureRegistration(void *ref, IONotificationPortRef *port,
                                        IOServiceInterestCallback cb, io_object_t *notifier) {
    io_connect_t connection = IORegisterForSystemPower(ref, port, cb, notifier);
    callback = cb;
    context = ref;
    powerPort = *port;
    return connection;
}

static void driveCallbacks(IONotificationPortRef port, dispatch_queue_t queue) {
    IONotificationPortSetDispatchQueue(port, queue);
    const char *command = getenv("HISTORY_TEST_POWER_COMMAND");
    if (!command || port != powerPort || timer) return;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        int fd = open(command, O_RDONLY);
        if (fd < 0) return;
        char phase = 0;
        ssize_t count = read(fd, &phase, 1);
        close(fd);
        unlink(command);
        if (count != 1) return;
        natural_t message = phase == 's' ? kIOMessageSystemWillSleep
            : (phase == 'w' ? kIOMessageSystemHasPoweredOn : kIOMessageSystemWillPowerOn);
        callback(context, IO_OBJECT_NULL, message, (void *)testToken);
        touch(getenv("HISTORY_TEST_POWER_DELIVERED"));
    });
    dispatch_resume(timer);
    touch(getenv("HISTORY_TEST_POWER_READY"));
}

static IOReturn ack(io_connect_t connection, long notification) {
    if (notification == testToken) {
        touch(getenv("HISTORY_TEST_POWER_ACK"));
        return kIOReturnSuccess;
    }
    return IOAllowPowerChange(connection, notification);
}

static AXError noWindowContents(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
    return kAXErrorAttributeUnsupported;
}

#define INTERPOSE(wrapper, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const void *const pair_##wrapper[] = {(const void *)wrapper, (const void *)original}
INTERPOSE(captureRegistration, IORegisterForSystemPower);
INTERPOSE(driveCallbacks, IONotificationPortSetDispatchQueue);
INTERPOSE(ack, IOAllowPowerChange);
INTERPOSE(noWindowContents, AXUIElementCopyAttributeValue);
'''


def wait_for(predicate, message):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError(message)


def exercise(binary, temp, interposer, recording):
    root = temp / ('recording' if recording else 'paused')
    root.mkdir()
    (root / 'control.json').write_text(json.dumps({'recording': recording, 'summarizing': False}))
    (root / 'config.json').write_text(json.dumps({'policy': {'defaultApplicationBehavior': 'do_not_observe'}}))
    probes = {name: root / name.lower() for name in ('READY', 'COMMAND', 'ACK', 'DELIVERED')}
    env = dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0', DYLD_INSERT_LIBRARIES=str(interposer))
    env.update({f'HISTORY_TEST_POWER_{name}': str(path) for name, path in probes.items()})
    away = root / 'away.json'

    def state():
        return json.loads(away.read_bytes()) if away.exists() else {}

    def event(kind):
        for name in ('ACK', 'DELIVERED'):
            probes[name].unlink(missing_ok=True)
        pending = probes['COMMAND'].with_suffix('.new')
        pending.write_text(kind)
        pending.replace(probes['COMMAND'])
        wait_for(probes['DELIVERED'].exists, f'power callback did not receive {kind}')

    with subprocess.Popen([binary, 'collect', '--out', root], env=env) as collector:
        try:
            wait_for(lambda: (root / 'collector.pid').exists(), 'collector did not publish identity')
            wait_for(probes['READY'].exists, 'collector did not register a system power callback')
            event('s')
            assert probes['ACK'].exists(), 'will-sleep notification was not acknowledged'
            first = state()
            if recording:
                assert first.get('systemSleep') is True and first.get('startedReason') == 'locked', first
                assert list((root / 'segments').glob('*/metadata.json')), 'sleep did not seal the active segment'
            else:
                assert not first, 'paused collector recorded a sleep interval'
            for phase in ('m', 's', 'm', 's'):
                event(phase)
                assert state() == first, 'maintenance wake changed the recorded sleep interval'
            event('w')
            assert not state().get('systemSleep'), 'full wake did not clear system-sleep state'
            if not recording:
                assert not away.exists()
            stop = subprocess.run([binary, '--stop', '--out', root], capture_output=True, timeout=10)
            assert stop.returncode == 0 and collector.wait(timeout=4) == 0, stop.stderr
        finally:
            if collector.poll() is None:
                collector.kill()
                collector.wait(timeout=4)


def main(binary):
    with tempfile.TemporaryDirectory(prefix='history-power-test-') as directory:
        temp = Path(directory)
        source, shim = temp / 'power.c', temp / 'power.dylib'
        source.write_text(SHIM)
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fblocks', '-framework', 'IOKit',
                        '-framework', 'ApplicationServices', source, '-o', shim], check=True)
        signer = shutil.which('local-codesign')
        ident = 'xyz.chesszyh.computer-history.power-test-probe'
        options = [signer, '--identifier', ident] if signer else ['codesign', '--force', '--sign', '-', '--identifier', ident]
        subprocess.run([*options, shim], check=True, stdout=subprocess.DEVNULL)
        exercise(binary, temp, shim, True)
        exercise(binary, temp, shim, False)
    print('PASS: the collector records sleep before acknowledgment; maintenance and pause preserve the interval rules')


if __name__ == '__main__':
    main(Path(sys.argv[1]).resolve())
