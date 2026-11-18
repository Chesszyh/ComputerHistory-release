#!/usr/bin/env python3
"""Check that background ten-minute retries stop resending rejected requests."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading


SID = '2020-01-01T00-00-00Z'
TIME = '2020-01-01T00:00:01Z'
PRIMARY = 'synthetic-primary'
FALLBACK = 'synthetic-fallback'
LIMIT = {
    PRIMARY: {'message': "This model's maximum context length is 1048576 tokens. "
                         'Your request has 1048577 tokens. Please reduce the length of the input.'},
    FALLBACK: {'message': 'The input exceeds the context window of this model.', 'code': 'context_too_large'},
}


class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model = request['model']
        self.server.calls.append((self.path, request))
        is_report = request['messages'][-1]['content'].startswith('报告：')
        if self.server.override:
            status, error = self.server.override(request)
        else:
            status, error = (200, None) if is_report else self.server.responses.get(model, (200, None))
        payload = {'error': error} if error else {
            'choices': [{'message': {'content': '### 本次活动\n- **更新测试文档**：补充合成回归结果。'},
                         'finish_reason': 'stop'}],
        }
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main(binary, server):
    env = dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0', TZ='UTC')
    endpoint = f'http://127.0.0.1:{server.server_port}/v1'

    def fixture(directory):
        root = Path(directory)
        segment = root / 'segments' / SID
        segment.mkdir(parents=True)
        source = segment / 'events.jsonl'
        source.write_text(json.dumps({'id': 1, 'timestamp': TIME, 'kind': 'mouse.click',
                                      'app': {'name': 'Synthetic Editor', 'bundleIdentifier': 'example.editor'}}) + '\n')
        (segment / 'metadata.json').write_text(json.dumps(dict(id=SID, startedAt='2020-01-01T00:00:00Z',
            endedAt=TIME, firstEventAt=TIME, eventCount=1, suppressedEventCount=0, eventsPath=str(source))))
        return root

    def config(root, primary=PRIMARY, budget=8192, fallback=FALLBACK):
        settings = dict(baseURL=endpoint, model=primary, outputTokenBudget=budget, requiresAPIKey=False)
        if fallback:
            settings['fallback'] = dict(baseURL=endpoint, model=fallback, outputTokenBudget=32768, requiresAPIKey=False)
        (root / 'model.json').write_text(json.dumps(settings))

    def run(root, *arguments, ok=None):
        start = len(server.calls)
        result = subprocess.run([binary, *arguments, '--out', root], env=env, capture_output=True, text=True, timeout=10)
        if ok is not None:
            assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
        return [request for _, request in server.calls[start:]]

    def background(root, **kwargs):
        return run(root, 'memorize', '--limit', '6', '--recent-first', **kwargs)

    def models(requests):
        return [request['model'] for request in requests]

    with tempfile.TemporaryDirectory(prefix='history-context-limit-') as directory:
        root = fixture(directory)
        config(root)
        server.responses = {model: (400, error) for model, error in LIMIT.items()}
        assert models(background(root, ok=False)) == [PRIMARY, FALLBACK]
        memory = next((root / 'memories').glob('*.md'))
        assert 'generation: failed' in memory.read_text()
        saved = (memory.stat().st_mtime_ns, memory.read_bytes())
        health = (root / 'model-health.json').read_bytes()
        assert background(root) == [], 'a new background worker resubmitted material rejected by both models'
        assert (memory.stat().st_mtime_ns, memory.read_bytes()) == saved, 'skipped requests rewrote the failed summary'
        assert (root / 'model-health.json').read_bytes() == health, 'skipped requests rewrote model health'
        assert len(list((root / 'requests').glob('*.json'))) == 2, 'skipped requests created usage records'
        assert run(root, 'report', '--day', '2020-01-01', ok=False) == [], 'report dependency resubmitted rejected material'

        healthy = root / 'memories/2020-01-01T00-10-00Z-ABCD-10min-memory-summary.md'
        healthy.write_text('---\ntitle: Synthetic\ndescription: Synthetic\ngeneration: model\n---\n'
                           '### 本次活动\n- **核对测试文档**：HEALTHY_REPORT_SOURCE。\n')
        requests = run(root, 'report', '--day', '2020-01-01', ok=True)
        assert len(requests) == 1 and 'HEALTHY_REPORT_SOURCE' in requests[0]['messages'][-1]['content']
        report = json.loads((root / 'reports/daily/2020-01-01.json').read_text())
        assert report['contextLimitedSegments'] == 1 and memory.name not in report['material']
        assert run(root, 'report', '--day', '2020-01-01', ok=True) == [], 'unchanged partial report was regenerated'
        assert len(run(root, 'report', '--kind', 'weekly', '--day', '2020-01-01', ok=True)) == 1
        weekly = json.loads((root / 'reports/weekly/2019-12-30.json').read_text())
        assert weekly['contextLimitedSegments'] == 1

        # An explicit overwrite can verify a server-side limit change without changing the local request.
        assert models(run(root, 'memorize', '--segment', SID, '--overwrite', ok=False)) == [PRIMARY, FALLBACK]

        # A new budget makes only the changed primary request eligible.
        config(root, budget=4096)
        assert models(background(root, ok=False)) == [PRIMARY]
        assert background(root) == []
        (root / 'summary.json').write_text(json.dumps({'tenMinutePrompt': 'Changed synthetic instructions'}))
        assert models(background(root, ok=False)) == [PRIMARY, FALLBACK]
        assert background(root) == []
        config(root, primary='synthetic-larger', budget=4096)
        assert models(background(root, ok=True)) == ['synthetic-larger']
        assert 'generation: model' in memory.read_text()
        assert len(run(root, 'report', '--day', '2020-01-01', ok=True)) == 1
        recovered = json.loads((root / 'reports/daily/2020-01-01.json').read_text())
        assert 'contextLimitedSegments' not in recovered and memory.name in recovered['material']

    with tempfile.TemporaryDirectory(prefix='history-context-legacy-') as directory:
        root = fixture(directory)
        config(root)
        for model, error in LIMIT.items():
            server.responses[model] = (400, error)
        initial = background(root, ok=False)
        assert models(initial) == [PRIMARY, FALLBACK]
        server.responses[FALLBACK] = (502, {'message': 'Bad gateway'})
        assert models(run(root, 'memorize', '--segment', SID, '--overwrite', ok=False)) == [PRIMARY, FALLBACK]
        # Reproduce an installation with only the pre-upgrade request ledger and failed memory.
        for path in (root / 'segments' / SID).iterdir():
            if path.name not in ('metadata.json', 'events.jsonl.gz'):
                path.unlink()
        assert background(root) == [], 'existing explicit context rejections were forgotten on upgrade'
        server.responses.pop(PRIMARY)
        assert models(run(root, 'memorize', '--segment', SID, '--overwrite', ok=True)) == [PRIMARY]
        next((root / 'memories').glob('*.md')).unlink()
        assert models(background(root, ok=True)) == [PRIMARY], 'successful explicit retry left a stale rejection'

    with tempfile.TemporaryDirectory(prefix='history-context-transient-') as directory:
        root = fixture(directory)
        config(root)
        server.responses = {PRIMARY: (400, LIMIT[PRIMARY]), FALLBACK: (503, {'message': 'Service unavailable'})}
        assert models(background(root, ok=False)) == [PRIMARY, FALLBACK]
        assert models(background(root, ok=False)) == [FALLBACK], 'a permanent primary rejection changed temporary fallback retry'
        server.responses[FALLBACK] = (400, {'code': 'invalid_request_error', 'message': 'Unsupported parameter'})
        assert models(background(root, ok=False)) == [FALLBACK]
        server.responses.pop(FALLBACK)
        assert models(background(root, ok=True)) == [FALLBACK], 'generic HTTP 400 was treated as context overflow'
        ledger = [json.loads(path.read_text()) for path in (root / 'requests').glob('*.json')]
        rejected = next(entry for entry in ledger if entry['model'] == PRIMARY)
        assert all(entry.get('fallbackOf') == rejected['id'] for entry in ledger if entry['model'] == FALLBACK)

    with tempfile.TemporaryDirectory(prefix='history-context-batches-') as directory:
        root = fixture(directory)
        source = root / 'segments' / SID / 'events.jsonl'
        axis = 'HEAD_OF_COMPLETE_INPUT ' + ''.join(f'观测{number:05d}详细内容。' for number in range(1800)) + ' TAIL_OF_COMPLETE_INPUT'
        with source.open('a') as stream:
            stream.write(json.dumps({'id': 2, 'timestamp': TIME, 'kind': 'window.changed',
                'app': {'name': 'Synthetic Editor', 'bundleIdentifier': 'example.editor'},
                'ax': {'mode': 'fullTree', 'text': '1 AXStaticText: Value: ' + axis}}) + '\n')
        group = lambda name, full: dict(id=name, name=name, model=name, baseURL=endpoint,
                                        fullInput=full, outputTokenBudget=8192, requiresAPIKey=False)
        def routed(primary_full, fallback_full):
            (root / 'model.json').write_text(json.dumps(dict(groups=[group('default', True),
                group(PRIMARY, primary_full), group(FALLBACK, fallback_full)], primaryGroupID='default',
                fallbackGroupID=FALLBACK, tasks={'10min': {'groupID': PRIMARY}})))
        accepted = []
        fail_next_batch = True
        def context_model(request):
            nonlocal fail_next_batch
            input = request['messages'][-1]['content']
            if request['model'] == PRIMARY:
                return 503, {'message': 'Synthetic primary busy'}
            if len(input.encode()) > 7500:
                return 400, LIMIT[FALLBACK]
            if input.startswith('从下面这一批'):
                if accepted and fail_next_batch:
                    fail_next_batch = False
                    return 503, {'message': 'Synthetic interrupted batch'}
                accepted.append(input)
            return 200, None
        routed(False, True)
        server.override = context_model
        initial = background(root, ok=False)
        assert models(initial[:2]) == [PRIMARY, FALLBACK]
        original_primary, original_fallback = [request['messages'][-1]['content'] for request in initial[:2]]
        assert 'TAIL_OF_COMPLETE_INPUT' not in original_primary and 'TAIL_OF_COMPLETE_INPUT' in original_fallback
        first_batch, = accepted
        resumed = background(root, ok=True)
        assert all(request['messages'][-1]['content'] not in (original_fallback, first_batch) for request in resumed)
        assert any('HEAD_OF_COMPLETE_INPUT' in text for text in accepted)
        assert any('TAIL_OF_COMPLETE_INPUT' in text for text in accepted)
        assert resumed[-1]['messages'][-1]['content'].startswith('合并以下同一十分钟时段')
        routed(True, False)
        requests = run(root, 'memorize', '--segment', SID, '--overwrite', ok=True)
        assert models(requests) == [PRIMARY, FALLBACK]
        assert 'TAIL_OF_COMPLETE_INPUT' in requests[0]['messages'][-1]['content']
        assert 'TAIL_OF_COMPLETE_INPUT' not in requests[1]['messages'][-1]['content']
        server.override = None


if __name__ == '__main__':
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    server.calls = []
    server.override = None
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        main(str(Path(sys.argv[1]).resolve()), server)
        print('PASS: remembered context rejection, legacy ledger, report dependency, changed settings and transient retry')
    finally:
        server.shutdown()
        server.server_close()
