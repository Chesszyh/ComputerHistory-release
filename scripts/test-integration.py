#!/usr/bin/env python3
"""Run independent synthetic integration checks concurrently with separate logs."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
CASES = ['process-control', 'text-summary', 'reports', 'model-fallback', 'scheduling']


def run_checks(binary, output, cases=CASES, jobs=5):
    output.mkdir(parents=True, exist_ok=True)

    def run(case):
        started = time.monotonic()
        print(f'START: {case}', flush=True)
        log = output / f'{case}.log'
        with log.open('w') as stream:
            try:
                result = subprocess.run([sys.executable, str(ROOT / 'scripts' / f'test-{case}.py'),
                                         str(binary)], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                        timeout=300)
                passed = result.returncode == 0
            except subprocess.TimeoutExpired:
                stream.write('\nFAIL: integration check exceeded 300 seconds\n')
                passed = False
        print(f'{"PASS" if passed else "FAIL"}: {case} ({time.monotonic() - started:.1f}s), {log}', flush=True)
        if not passed:
            print(log.read_text(), flush=True)
        return passed

    with ThreadPoolExecutor(max_workers=jobs) as executor:
        results = [future.result() for future in as_completed([executor.submit(run, case) for case in cases])]
    return all(results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--logs', type=Path, required=True)
    parser.add_argument('--jobs', type=int, choices=range(1, 6), default=5)
    args = parser.parse_args()
    return 0 if run_checks(args.binary.resolve(), args.logs.resolve(), jobs=args.jobs) else 1


if __name__ == '__main__':
    sys.exit(main())
