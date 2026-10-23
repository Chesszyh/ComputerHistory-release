#!/usr/bin/env python3
"""用本地模拟模型断言实际摘要请求中的文本证据；仅使用临时合成数据。"""
import fcntl
import time as monotonic_time
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
            numbers = re.findall(r'### 来源 (S\d+)', user)
            if mode == 'continuity' and '### 已有活动 P1' in user:
                numbers.insert(0, 'P1')
            content = f'## [{",".join(numbers)}] 合成活动\n查看了合成窗口并编辑合成文档。'
        else:
            content = '### Memory summary\n合成摘要。\n### 本次活动\n查看了合成窗口。'
        if payload['model'] == 'synthetic-shadow':
            content = 'SHADOW OUTPUT'
        if mode == 'empty':
            content = ''
        if mode == 'invalid_sources' and '待整理的新增活动' in user:
            content = '## [S99] 不存在的来源\n合成内容。'
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
        key_check = subprocess.run([binary, 'model-key', '--check', '--out', directory], env=env,
                                   capture_output=True, text=True, timeout=5)
        assert key_check.returncode != 0 and '没有保存密钥' in key_check.stderr, key_check.stdout + key_check.stderr
        assert '辅助功能权限' not in key_check.stdout
        invalid_check = subprocess.run([binary, 'model-key', '--check', '--authorize', '--out', directory],
                                       env=env, capture_output=True, text=True, timeout=5)
        assert invalid_check.returncode != 0 and '不能同时使用' in invalid_check.stderr
        (root / 'model.json').write_text('{broken')
        for command in ['memorize', 'narrative', 'report']:
            args = [binary, command, '--out', directory]
            if command == 'report':
                args += ['--day', '2020-01-01']
            invalid = subprocess.run(args, env=env, capture_output=True, text=True, timeout=30)
            assert invalid.returncode != 0 and 'model.json' in invalid.stderr, (command, invalid.stdout, invalid.stderr)
        assert not list((root / 'memories').glob('*.md')), 'invalid configuration marked a segment complete'
        assert not requests
        (root / 'model.json').unlink()
        repaired = subprocess.run([binary, 'memorize', '--out', directory], env=env,
                                  capture_output=True, text=True, timeout=30)
        assert repaired.returncode == 0 and len(requests) == 1, repaired.stderr
        next((root / 'memories').glob('*.md')).unlink()
        requests.clear()
        authorizations.clear()
        for ledger_file in (root / 'requests').glob('*.json'):
            ledger_file.unlink()
        (root / 'model.json').write_text('{broken')
        local = subprocess.run([binary, 'memorize', '--out', directory, '--no-model', '--segment', segment_id],
                               env=env, capture_output=True, text=True, timeout=30)
        assert local.returncode == 0 and not requests
        assert 'generation: factual' in next((root / 'memories').glob('*.md')).read_text()
        # An explicit factual result remains complete when model configuration becomes available.
        (root / 'model.json').unlink()
        unchanged = subprocess.run([binary, 'memorize', '--out', directory], env=env,
                                   capture_output=True, text=True, timeout=30)
        assert unchanged.returncode == 0 and not requests
        next((root / 'memories').glob('*.md')).unlink()
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
            sid = (segment_id + f'_00000000-0000-0000-0000-{minute:012d}' if minute in [10, 20]
                   else f'2020-01-01T{minute // 60:02d}-{minute % 60:02d}-00Z')
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
        before = len(requests)
        no_change = subprocess.run([binary, 'narrative', '--out', directory], env=local_env,
                                   capture_output=True, text=True, timeout=30)
        assert no_change.returncode == 0 and len(requests) == before, 'unchanged sources were charged again'
        source = root / 'memories' / saved['items'][0]['sourceMemories'][0]
        source.write_text(source.read_text() + '\nSYNTHETIC REVISION CORRECTED\n')
        unchanged_item = saved['items'][1]
        original_cache = (root / 'narrative.json').read_bytes()
        for failure_mode in ['http_error', 'invalid_sources']:
            mode = failure_mode
            failed_revision = subprocess.run([binary, 'narrative', '--out', directory], env=local_env,
                                              capture_output=True, text=True, timeout=30)
            assert failed_revision.returncode != 0, failed_revision.stdout
            assert (root / 'narrative.json').read_bytes() == original_cache, 'failed revision destroyed the usable cache'
        mode = 'ok'
        before = len(requests)
        revised = subprocess.run([binary, 'narrative', '--out', directory], env=local_env,
                                 capture_output=True, text=True, timeout=30)
        assert revised.returncode == 0 and len(requests) == before + 1, revised.stderr
        refreshed = json.loads((root / 'narrative.json').read_text())
        assert unchanged_item in refreshed['items'], 'unrelated item was recomputed'
        assert len({name for item in refreshed['items'] for name in item['sourceMemories']}) == 8
        before = len(requests)
        subprocess.run([binary, 'narrative', '--out', directory], env=local_env,
                       capture_output=True, text=True, timeout=30, check=True)
        assert len(requests) == before
        mode = 'continuity'
        continuation_root = root / 'continuation'
        continuation_memories = continuation_root / 'memories'
        continuation_memories.mkdir(parents=True)
        (continuation_root / 'model.json').write_text(json.dumps(config))
        def continue_narrative():
            return subprocess.run([binary, 'narrative', '--out', str(continuation_root)], env=local_env,
                                  capture_output=True, text=True, timeout=30)
        for minute in [0, 10]:
            name = f'2020-01-01T00-{minute:02d}-00Z-ABCD-10min-memory-summary.md'
            (continuation_memories / name).write_text(template)
            result = continue_narrative()
            assert result.returncode == 0, result.stderr
        continued = json.loads((continuation_root / 'narrative.json').read_text())
        assert len(continued['items']) == 1, 'incremental generation did not extend the existing activity'
        assert len(continued['items'][0]['sourceMemories']) == 2, 'continuation lost an earlier source'
        before = len(requests)
        assert continue_narrative().returncode == 0 and len(requests) == before
        previous_id = continued['items'][0]['id']
        (continuation_root / 'timeline-deletions.json').write_text(json.dumps({'ids': ['narrative:' + previous_id]}))
        (continuation_memories / '2020-01-01T00-20-00Z-ABCD-10min-memory-summary.md').write_text(template)
        assert continue_narrative().returncode == 0
        continued = json.loads((continuation_root / 'narrative.json').read_text())
        assert len(continued['items']) == 2, 'new activity was hidden by merging into a deleted activity'
        assert '### 已有活动 P1' not in requests[-1]['messages'][-1]['content']

        away_root = root / 'away-continuation'
        away_memories = away_root / 'memories'
        away_memories.mkdir(parents=True)
        (away_root / 'model.json').write_text(json.dumps(config))
        def away_narrative(overwrite=False):
            return subprocess.run([binary, 'narrative', '--out', str(away_root)] + (['--overwrite'] if overwrite else []), env=local_env,
                                  capture_output=True, text=True, timeout=30)
        def add_away_source(time, first):
            segment_id = '2020-01-01T' + time.replace(':', '-') + 'Z'
            (away_memories / (segment_id + '-ABCD-10min-memory-summary.md')).write_text(template)
            segment = away_root / 'segments' / segment_id
            segment.mkdir(parents=True)
            (segment / 'metadata.json').write_text(json.dumps({
                'id': segment_id, 'startedAt': '2020-01-01T' + time + 'Z',
                'firstEventAt': '2020-01-01T' + first + 'Z', 'eventCount': 1,
                'suppressedEventCount': 0, 'eventsPath': str(segment / 'events.jsonl')}))
        for time in ['00:00:00', '00:10:00']:
            add_away_source(time, time)
        assert away_narrative().returncode == 0
        periods = [{'start': '2020-01-01T00:15:00Z', 'end': '2020-01-01T08:06:00Z'}]
        (away_root / 'away.json').write_text(json.dumps({'periods': periods}))
        add_away_source('08:00:00', '08:06:00')
        assert away_narrative().returncode == 0
        assert '### 已有活动 P1' not in requests[-1]['messages'][-1]['content'], 'pre-sleep activity offered for continuation after wake'
        assert len(json.loads((away_root / 'narrative.json').read_text())['items']) == 2
        periods.append({'start': '2020-01-01T08:20:00Z', 'end': '2020-01-01T10:05:00Z'})
        (away_root / 'away.json').write_text(json.dumps({'periods': periods}))
        add_away_source('08:10:00', '08:10:00')
        add_away_source('10:00:00', '10:05:00')
        before = len(requests)
        assert away_narrative().returncode == 0
        assert len(requests) == before + 2, 'one model batch crossed an away boundary'
        saved = json.loads((away_root / 'narrative.json').read_text())
        assert len(saved['items']) == 3
        assert sorted(len(i['sourceMemories']) for i in saved['items']) == [1, 2, 2]
        legacy = saved['items'][0].copy()
        legacy.update(id='legacy-all-day', timestamp='2020-01-01T00:00:00Z',
                      sourceMemories=[s for i in saved['items'] for s in i['sourceMemories']],
                      sourceRevisions={s: r for i in saved['items'] for s, r in i['sourceRevisions'].items()})
        (away_root / 'narrative.json').write_text(json.dumps(dict(saved, items=[legacy])))
        before = len(requests)
        legacy_cache = (away_root / 'narrative.json').read_bytes()
        assert away_narrative().returncode == 0 and len(requests) == before, 'stable history was recalculated without user choice'
        fail_at = len(requests) + 2
        assert away_narrative(overwrite=True).returncode != 0
        interrupted = json.loads((away_root / 'narrative.json').read_text())
        assert sorted(s for i in interrupted['items'] for s in i['sourceMemories']) == sorted(legacy['sourceMemories']), 'partial repair lost sources from another episode'
        assert (away_root / 'narrative.json').read_bytes() == legacy_cache, 'failed day rebuild replaced existing summaries'
        fail_at = None
        before = len(requests)
        assert away_narrative(overwrite=True).returncode == 0
        assert len(requests) == before + 3
        repaired = json.loads((away_root / 'narrative.json').read_text())
        assert len(repaired['items']) == 3
        assert all('legacy-all-day' in i.get('previousIDs', []) for i in repaired['items'])
        before = len(requests)
        assert away_narrative().returncode == 0 and len(requests) == before
        fixed_root = root / 'fixed-mode'
        fixed_memories = fixed_root / 'memories'
        fixed_memories.mkdir(parents=True)
        (fixed_root / 'model.json').write_text(json.dumps(config))
        (fixed_root / 'summary.json').write_text(json.dumps({'timelineMode': 'fixed10min'}))
        for day in ['2020-01-01', '2020-01-02']:
            for minute in [0, 10, 20]:
                (fixed_memories / f'{day}T00-{minute:02d}-00Z-ABCD-10min-memory-summary.md').write_text(template)
        fixed_command = [binary, 'narrative', '--out', str(fixed_root)]
        before = len(requests)
        subprocess.run(fixed_command, env=local_env, capture_output=True, check=True, timeout=30)
        assert len(requests) == before + 6, 'fixed mode must generate one request per source'
        fixed_cache = fixed_root / 'narrative.json'
        fixed_items = json.loads(fixed_cache.read_text())['items']
        assert len(fixed_items) == 6 and all(len(i['sourceMemories']) == 1 for i in fixed_items)
        assert all(i['generationMode'] == 'fixed10min' for i in fixed_items)
        assert all('### 已有活动 P1' not in r['messages'][-1]['content'] for r in requests[before:])
        # Changing mode alone must preserve existing automatic text and incur no calls.
        original = fixed_cache.read_bytes()
        (fixed_root / 'summary.json').write_text(json.dumps({'timelineMode': 'continuous'}))
        before = len(requests)
        subprocess.run(fixed_command, env=local_env, capture_output=True, check=True, timeout=30)
        assert len(requests) == before and fixed_cache.read_bytes() == original
        other_day = [i for i in fixed_items if '2020-01-02' in i['sourceMemories'][0]]
        subprocess.run(fixed_command + ['--overwrite', '--day', '2020-01-01'], env=local_env,
                       capture_output=True, check=True, timeout=30)
        rebuilt = json.loads(fixed_cache.read_text())['items']
        assert len(rebuilt) == 4 and all(i in rebuilt for i in other_day), 'day scope rewrote another day'
        subprocess.run(fixed_command + ['--overwrite'], env=local_env,
                       capture_output=True, check=True, timeout=30)
        assert len(json.loads(fixed_cache.read_text())['items']) == 2
        # Explicit rebuild reports lock contention; waiting succeeds only after release.
        lock_file = fixed_root / '.locks/narrative.lock'
        with lock_file.open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            blocked = subprocess.run(fixed_command + ['--overwrite'], env=local_env,
                                     capture_output=True, timeout=10)
            assert blocked.returncode == 75
            waiting = subprocess.Popen(fixed_command + ['--overwrite', '--wait-lock'], env=local_env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                monotonic_time.sleep(0.3)
                assert waiting.poll() is None
                fcntl.flock(lock, fcntl.LOCK_UN)
                output, error = waiting.communicate(timeout=30)
                assert waiting.returncode == 0, error
            finally:
                if waiting.poll() is None:
                    waiting.terminate()
                    waiting.wait(timeout=5)
        mode = 'ok'
        config['fallback'] = {'baseURL': config['baseURL'], 'model': 'synthetic-shadow',
                              'requiresAPIKey': False, 'reasoningEffort': 'none'}
        (root / 'model.json').write_text(json.dumps(config))
        before = len(requests)
        assert regenerate().returncode == 0
        assert len(requests) == before + 1, 'healthy primary must not call the fallback'
        print('PASS: evidence, request ledger, pricing, failure/empty usage, budgets, batch resume, prompt overrides, fixed/continuous modes, scoped rebuilds, lock waiting, and fallback idle on primary success')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
