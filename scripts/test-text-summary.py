#!/usr/bin/env python3
"""用本地模拟模型断言实际摘要请求中的文本证据；仅使用临时合成数据。"""
import http.server
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

os.environ["COMPUTER_HISTORY_NOTIFICATIONS"] = "0"

binary = str(Path(sys.argv[1]).resolve())
requests = []
mode = "ok"
fail_at = None
authorizations = []

class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(payload)
        authorizations.append(self.headers.get('Authorization'))
        if mode == 'http_error' or len(requests) == fail_at:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b'synthetic unavailable')
            return
        user = next(m['content'] for m in payload['messages'] if m['role'] == 'user')
        if '待整理的新增活动' in user:
            at = re.search(r'### 时刻 (\d{2}:\d{2})', user).group(1)
            content = f'## {at} 合成活动\n查看了合成窗口并编辑合成文档。'
        else:
            content = '### Memory summary\n合成摘要。\n### 本次活动\n查看了合成窗口。'
        if payload['model'] == 'synthetic-shadow':
            content = 'SHADOW OUTPUT'
        if mode == 'empty':
            content = ''
        body = json.dumps({'choices': [{'message': {'content': content}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 30, 'total_tokens': 130, 'prompt_cache_hit_tokens': 20, 'completion_tokens_details': {'reasoning_tokens': 0}}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix='text-summary-') as directory:
    root = Path(directory)
    segment_id = '2020-01-01T00-00-00Z'
    segment = root / 'segments' / segment_id
    segment.mkdir(parents=True)
    events = []
    for i in range(35):
        keyboard = {'text': f'fragment-{i}'}
        if i >= 30:
            keyboard.update(text=f'effective-{i}', textEvidence='edited_value', focusIdentity=7)
        events.append({'id': i, 'timestamp': f'2020-01-01T00:00:{i:02d}Z', 'kind': 'keyboard.text_input',
                       'app': {'name': 'Fixture', 'bundleIdentifier': 'com.example.editor'},
                       'window': {'title': 'Synthetic', 'windowID': 1}, 'keyboard': keyboard})
    events.append({'id': 35, 'timestamp': '2020-01-01T00:00:35Z', 'kind': 'keyboard.text_input',
                   'app': {'name': 'Fixture', 'bundleIdentifier': 'com.example.editor'},
                   'keyboard': {'text': 'synthetic-placeholder', 'target': {'placeholder': 'synthetic-placeholder'}}})
    (segment / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
    (segment / 'metadata.json').write_text(json.dumps({'id': segment_id, 'startedAt': '2020-01-01T00:00:00Z', 'endedAt': '2020-01-01T00:00:35Z', 'eventCount': len(events), 'suppressedEventCount': 0, 'eventsPath': str(segment / 'events.jsonl')}))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(os.environ, DEEPSEEK_API_KEY='synthetic-key',
               DEEPSEEK_BASE_URL=f'http://127.0.0.1:{server.server_port}')
    try:
        result = subprocess.run([binary, 'memorize', '--out', directory, '--segment', segment_id],
                                env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert len(requests) == 1, f'expected one local request, got {len(requests)}'
        assert (segment / 'events.jsonl.gz').exists() and not (segment / 'events.jsonl').exists()
        status = subprocess.run([binary, '--status', '--out', directory], env=env,
                                capture_output=True, text=True, timeout=30)
        assert status.returncode == 0 and f'事件总数：{len(events)}' in status.stdout, status.stdout

        user = next(m['content'] for m in requests[0]['messages'] if m['role'] == 'user')
        assert 'effective-34' in user
        assert 'fragment-0' in user and 'fragment-29' in user
        assert 'synthetic-placeholder' not in user
        assert '控件变化' in user
        assert '不证明发送或逐字键入' not in user
        assert 'reasoning_effort' not in requests[0]
        assert f'{segment_id}#34' in user
        text = next((root / 'memories').glob('*.md')).read_text()
        assert 'effective-34' in text and '控件变化' in text
        narrative = subprocess.run([binary, 'narrative', '--out', directory, '--overwrite'],
                                   env=env, capture_output=True, text=True, timeout=30)
        assert narrative.returncode == 0, narrative.stderr
        assert len(requests) == 2, f'expected second local narrative request, got {len(requests)}'
        narrative_user = next(m['content'] for m in requests[1]['messages'] if m['role'] == 'user')
        assert '文本证据：本段含未确认归因的值变化' not in narrative_user
        assert '不能把这些片段写成用户输入、发送或完成' not in narrative_user
        ledger = [json.loads(p.read_text()) for p in (root / 'requests').glob('*.json')]
        assert len(ledger) == 2 and all(r['status'] == 'success' for r in ledger)
        assert all(r['usage']['cachedPromptTokens'] == 20 for r in ledger)
        assert all(r['usage']['totalTokens'] == 130 for r in ledger)
        assert all(r['system'] and r['input'] and r['output'] for r in ledger)
        config = {'baseURL': f'http://127.0.0.1:{server.server_port}/v1', 'model': 'synthetic-local',
                  'requiresAPIKey': False, 'reasoningEffort': 'none',
                  'pricing': {'currency': 'CNY', 'inputPerMillion': 2, 'cachedInputPerMillion': 0.04, 'outputPerMillion': 8}}
        (root / 'model.json').write_text(json.dumps(config))
        local_env = {k: v for k, v in env.items() if not k.startswith('DEEPSEEK_')}
        def regenerate():
            return subprocess.run([binary, 'memorize', '--out', directory, '--segment', segment_id, '--overwrite'],
                                  env=local_env, capture_output=True, text=True, timeout=30)
        summary_settings = {
            'tenMinutePrompt': requests[0]['messages'][0]['content'] + '\nSYNTHETIC TEN MINUTE OVERRIDE',
            'sixHourPrompt': 'SYNTHETIC SIX HOUR OVERRIDE',
            'narrativePrompt': requests[1]['messages'][0]['content'] + '\nSYNTHETIC NARRATIVE OVERRIDE',
        }
        (root / 'summary.json').write_text(json.dumps(summary_settings))
        assert regenerate().returncode == 0
        assert requests[-1]['messages'][0]['content'] == summary_settings['tenMinutePrompt']
        assert authorizations[-1] is None, 'remote unkeyed server received an unrelated cloud credential'
        records = [json.loads(p.read_text()) for p in (root / 'requests').glob('*.json')]
        priced = next(r for r in records if r['model'] == 'synthetic-local')
        assert abs(priced['estimatedCost'] - 0.0004008) < 1e-9
        assert priced['pricing'] == config['pricing']
        narrative = subprocess.run([binary, 'narrative', '--out', directory, '--overwrite'],
                                   env=local_env, capture_output=True, text=True, timeout=30)
        assert narrative.returncode == 0, narrative.stderr
        assert requests[-1]['messages'][0]['content'] == summary_settings['narrativePrompt']
        six_hour = subprocess.run([binary, 'memorize', '--out', directory, '--granularity', '6h'],
                                  env=local_env, capture_output=True, text=True, timeout=30)
        assert six_hour.returncode == 0, six_hour.stderr
        assert requests[-1]['messages'][0]['content'] == summary_settings['sixHourPrompt']
        before = len(requests)
        (root / 'summary.json').write_text('{"tenMinutePrompt": " "}')
        invalid = regenerate()
        assert invalid.returncode != 0 and 'summary.json' in invalid.stderr
        assert len(requests) == before, 'invalid summary settings sent a model request'
        # No-model generation remains local even while model prompt settings are broken.
        factual = subprocess.run([binary, 'memorize', '--out', directory, '--segment', segment_id,
                                  '--overwrite', '--no-model'], env=local_env,
                                 capture_output=True, text=True, timeout=30)
        assert factual.returncode == 0 and len(requests) == before
        (root / 'summary.json').write_text(json.dumps(summary_settings))
        mode = 'http_error'
        assert regenerate().returncode != 0  # failure is reported while the factual memory remains available
        records = [json.loads(p.read_text()) for p in (root / 'requests').glob('*.json')]
        failed = next(r for r in records if r['status'] == 'failed')
        assert failed.get('usage') is None and failed.get('estimatedCost') is None
        assert '503' in failed['error']
        mode = 'empty'
        assert regenerate().returncode != 0
        records = [json.loads(p.read_text()) for p in (root / 'requests').glob('*.json')]
        assert any(r['status'] == 'empty' and r['usage']['totalTokens'] == 130 for r in records)
        before = len(requests)
        config['dailyBudget'] = 0
        (root / 'model.json').write_text(json.dumps(config))
        assert regenerate().returncode != 0
        assert len(requests) == before, 'budget limit still sent a model request'
        del config['dailyBudget']
        (root / 'model.json').write_text(json.dumps(config))
        mode = 'ok'
        # Eight sources require two requests; a failed second batch must preserve the first.
        template = next((root / 'memories').glob('*.md')).read_text()
        for minute in range(10, 80, 10):
            sid = f'2020-01-01T{minute // 60:02d}-{minute % 60:02d}-00Z'
            (root / 'memories' / f'{sid}-ABCD-10min-memory-summary.md').write_text(template)
        (root / 'narrative.json').unlink()
        fail_at = len(requests) + 2
        narrative = subprocess.run([binary, 'narrative', '--out', directory], env=local_env,
                                   capture_output=True, text=True, timeout=30)
        saved = json.loads((root / 'narrative.json').read_text())
        assert len({name for item in saved['items'] for name in item['sourceMemories']}) == 4
        fail_at = None
        before = len(requests)
        narrative = subprocess.run([binary, 'narrative', '--out', directory], env=local_env,
                                   capture_output=True, text=True, timeout=30)
        assert narrative.returncode == 0, narrative.stderr
        assert len(requests) == before + 1, 'saved batch was charged again on resume'
        saved = json.loads((root / 'narrative.json').read_text())
        assert len({name for item in saved['items'] for name in item['sourceMemories']}) == 8
        config['fallback'] = {'baseURL': config['baseURL'], 'model': 'synthetic-shadow',
                              'requiresAPIKey': False, 'reasoningEffort': 'none'}
        (root / 'model.json').write_text(json.dumps(config))
        before = len(requests)
        assert regenerate().returncode == 0
        assert len(requests) == before + 1, 'healthy primary must not call the fallback'
        print('PASS: evidence, request ledger, pricing, failure/empty usage, budgets, batch resume, prompt overrides, and fallback idle on primary success')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
