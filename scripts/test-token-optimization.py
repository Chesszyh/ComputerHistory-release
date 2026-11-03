#!/usr/bin/env python3
"""Verify stage routing and reuse of unchanged group summaries with a local API."""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading

calls = []
invalid_planner = False
class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append(data)
        assert self.headers.get('Authorization') is None
        system, user = [message['content'] for message in data['messages']]
        if '只决定归属' in system:
            assert data['model'] in ['planner', 'writer']
            if data['model'] == 'planner':
                assert data['reasoning_effort'] == 'none' and data['max_tokens'] == 1024
            refs = re.findall(r'^#### 活动 (S\d+\.A\d+)$', user, re.M)
            text = json.dumps({'groups': [{'references': [ref], 'continuesPrevious': False, 'task': None} for ref in refs]})
        else:
            assert data['model'] == 'writer' and data['reasoning_effort'] in ['none', 'low']
            assert data['max_tokens'] == 2048
            text = json.dumps({'title': '核对合成事项', 'summary': '核对合成材料的动作与结果。'})
        if invalid_planner and data['model'] == 'planner': text = 'Synthetic non-JSON response'
        body = json.dumps({'choices': [{'message': {'content': text}, 'finish_reason': 'stop'}]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass

binary = str(Path(sys.argv[1]).resolve())
server = http.server.HTTPServer(('127.0.0.1', 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='token-optimization-') as directory:
        root = Path(directory); (root/'memories').mkdir()
        config = {'groups': [{'id': name, 'name': name, 'model': name, 'requiresAPIKey': False,
                             'baseURL': f'http://127.0.0.1:{server.server_port}'} for name in ['primary', 'planner', 'writer']],
                  'primaryGroupID': 'primary', 'tasks': {'narrative-grouping': {'groupID': 'planner', 'reasoningEffort': 'none', 'outputTokenBudget': 1024},
                  'narrative': {'groupID': 'writer', 'reasoningEffort': 'none', 'outputTokenBudget': 2048}}}
        (root/'model.json').write_text(json.dumps(config))
        memory = root/'memories/2020-01-01T00-00-00Z-ABCD-10min-memory-summary.md'
        initial = '---\ntitle: Synthetic\ndescription: Synthetic\n---\n### 本次活动\n- **核对甲**：SYNTHETIC_A。\n- **核对乙**：SYNTHETIC_B。'
        memory.write_text(initial)
        def run(overwrite=False):
            p = subprocess.run([binary, 'narrative', '--out', str(root)] + (['--overwrite'] if overwrite else []),
                capture_output=True, text=True, timeout=30, env=dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0'))
            assert p.returncode == 0, p.stderr
        run(); assert len(calls) == 3
        run(); assert len(calls) == 3, 'unchanged timeline sent requests'
        memory.write_text(initial + '\n- **核对丙**：SYNTHETIC_C。')
        before = len(calls); run()
        assert len(calls) == before + 2, 'unchanged groups were summarized again after a batch revision'
        before = len(calls); run(overwrite=True)
        assert len(calls) == before + 4, 'explicit overwrite reused cached summaries'
        config['tasks']['narrative']['reasoningEffort'] = 'low'
        (root/'model.json').write_text(json.dumps(config))
        (root/'narrative.json').unlink()
        before = len(calls); run()
        assert len(calls) == before + 4, 'changed generation settings reused old summaries'
        assert all('SYNTHETIC_C' not in call['messages'][1]['content'] for call in calls[:3] if call['model'] == 'writer')
        config['fallbackGroupID'] = 'writer'
        (root/'model.json').write_text(json.dumps(config))
        (root/'narrative.json').unlink()
        invalid_planner = True
        before = len(calls); run()
        assert calls[before]['model'] == 'planner' and calls[before+1]['model'] == 'writer'
        ledger = [json.loads(p.read_text()) for p in (root/'requests').glob('*.json')]
        invalid = [r for r in ledger if r['status'] == 'invalid']
        assert invalid and any(r.get('fallbackOf') == invalid[0]['id'] for r in ledger)
        invalid_planner = False
        config.pop('fallbackGroupID')
        config['groups'][1]['requiresAPIKey'] = True
        (root/'model.json').write_text(json.dumps(config))
        (root/'narrative.json').unlink()
        before = len(calls)
        result = subprocess.run([binary, 'narrative', '--out', str(root)], capture_output=True, text=True, timeout=30,
            env=dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0', DEEPSEEK_API_KEY='synthetic-unrelated-key'))
        assert result.returncode != 0 and len(calls) == before, 'primary environment key leaked to an independent task group'
        result = subprocess.run([binary, 'narrative', '--out', str(root), '--no-model', '--overwrite'],
            capture_output=True, text=True, timeout=30, env=dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0'))
        assert result.returncode == 0 and len(calls) == before, '--no-model allowed stage routing to call an API'
        print('PASS: per-task models, reasoning and budgets; keyless routing; batch revisions reuse unchanged groups; explicit overwrite and changed settings regenerate')
finally:
    server.shutdown(); server.server_close()
