#!/usr/bin/env python3
"""Verify activity-level narrative updates with synthetic memories and a local model."""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading


requests = []
response_mode = 'separate'


class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        user = payload['messages'][-1]['content']
        requests.append(user)
        references = re.findall(r'^#### 活动 (S\d+\.A\d+)$', user, re.M)
        items = []
        for index, reference in enumerate(references):
            claim = ('P1,' if response_mode == 'continue' and index == 0 and '### 已有活动 P1' in user else '') + reference
            items.append(f'## [{claim}] 核查合成事项 {index + 1}。\n核对合成材料和可观察的结果。')
        if response_mode == 'invalid':
            items = items[:1]
        if response_mode == 'roles':
            items = [f'## [{references[0]},+{references[1]},~{references[2]}] 迁移示例项目\n核对目录与压缩结果。',
                     f'## [{references[3]}] 阅读示例论文\n讨论研究问题。']
        if response_mode == 'aside_continuation':
            items = [f'## [~{references[0]}] 期间的其他活动\n短暂查看天气。']
        if response_mode == 'fixed':
            items = [f'## [{source}] 核对合成活动\n保留原有活动。' for source in re.findall(r'^### 来源 (S\d+)', user, re.M)]
        body = json.dumps({'choices': [{'message': {'content': '\n\n'.join(items)}, 'finish_reason': 'stop'}],
                           'usage': {'prompt_tokens': 100, 'completion_tokens': 100, 'total_tokens': 200}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    global response_mode
    binary = str(Path(sys.argv[1]).resolve())
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='narrative-activities-') as directory:
            root = Path(directory)
            memories = root / 'memories'
            memories.mkdir()
            (root / 'model.json').write_text(json.dumps({'baseURL': f'http://127.0.0.1:{server.server_port}',
                'model': 'synthetic', 'requiresAPIKey': False, 'allowInsecureHTTP': True}))
            env = dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0')
            def generate(success=True, overwrite=False):
                result = subprocess.run([binary, 'narrative', '--out', str(root)] + (['--overwrite'] if overwrite else []),
                                        env=env, capture_output=True, text=True, timeout=30)
                assert (result.returncode == 0) == success, result.stderr
                return json.loads((root / 'narrative.json').read_text()) if success else None

            def memory(minute, activities):
                file = memories / f'2020-01-01T00-{minute:02d}-00Z-ABCD-10min-memory-summary.md'
                file.write_text('---\ntitle: Synthetic window\ndescription: Synthetic counts\n---\n## Memory summary\n### 本次活动\n' + activities)
                return file

            first = memory(0, '- **核查报告**：SYNTHETIC_EARLY_RESULT。\n- **迁移示例项目**：SYNTHETIC_MIGRATION_DETAIL。')
            initial = generate()
            assert len(initial['items']) == 2
            assert len({item['id'] for item in initial['items']}) == 2
            assert all(not item['title'].endswith('。') for item in initial['items'])
            assert {tuple(item['sourceActivities'][first.name]) for item in initial['items']} == {(1,), (2,)}
            before = len(requests)
            assert generate() == initial and len(requests) == before
            # Only the final activity can be offered for continuation; its sibling stays intact.
            sibling = next(item for item in initial['items'] if item['sourceActivities'][first.name] == [1])
            second = memory(10, '- **迁移示例项目**：SYNTHETIC_LATEST_RESULT。')
            response_mode = 'continue'
            continued = generate()
            assert sibling in continued['items'], 'continuation removed another activity in the shared source'
            assert len(continued['items']) == 2
            assert 'SYNTHETIC_MIGRATION_DETAIL' in requests[-1]
            prior = requests[-1].split('## 待整理的新增活动')[0]
            assert 'SYNTHETIC_EARLY_RESULT' not in prior, 'unrelated sibling leaked into continuation material'
            assert any(set(item['sourceMemories']) == {first.name, second.name} for item in continued['items'])
            # A failed whole-day rewrite must leave the cache unchanged.
            original = (root / 'narrative.json').read_bytes()
            response_mode = 'invalid'
            generate(success=False, overwrite=True)
            assert (root / 'narrative.json').read_bytes() == original
            # Source revision regenerates all activities without dropping earlier or later sources.
            first.write_text(first.read_text().replace('SYNTHETIC_EARLY_RESULT', 'SYNTHETIC_CORRECTED_RESULT'))
            response_mode = 'separate'
            revised = generate()
            assert len(revised['items']) == 3
            assert {name for item in revised['items'] for name in item['sourceMemories']} == {first.name, second.name}
            assert len({item['id'] for item in revised['items']}) == 3
            # Fixed mode still produces exactly one item per memory.
            (root / 'summary.json').write_text(json.dumps({'timelineMode': 'fixed10min'}))
            response_mode = 'fixed'
            fixed = generate(overwrite=True)
            assert len(fixed['items']) == 2
            assert all(len(item['sourceMemories']) == 1 for item in fixed['items'])
            role_root = root / 'roles'
            role_memories = role_root / 'memories'
            role_memories.mkdir(parents=True)
            (role_root / 'model.json').write_bytes((root / 'model.json').read_bytes())
            role_file = role_memories / '2020-01-01T00-00-00Z-ABCD-10min-memory-summary.md'
            role_file.write_text('---\ntitle: Synthetic\ndescription: Counts\n---\n### 本次活动\n'
                '- **迁移项目**：SYNTHETIC_MIGRATION。\n- **压缩初测**：SYNTHETIC_COMPRESSION。\n'
                '- **查看天气**：SYNTHETIC_WEATHER。\n- **阅读论文**：SYNTHETIC_PAPER。')
            def generate_roles():
                subprocess.run([binary, 'narrative', '--out', str(role_root)], env=env, capture_output=True,
                               text=True, timeout=30, check=True)
                return json.loads((role_root / 'narrative.json').read_text())
            response_mode = 'roles'
            grouped = generate_roles()
            assert len(grouped['items']) == 2, 'steps and asides must not each require a card'
            migration = next(item for item in grouped['items'] if item['title'] == '迁移示例项目')
            assert migration['sourceActivities'][role_file.name] == [1, 2, 3]
            assert migration['sourceSteps'][role_file.name] == [2]
            assert migration['sourceIncidental'][role_file.name] == [3]
            later = role_memories / '2020-01-01T00-10-00Z-ABCD-10min-memory-summary.md'
            later.write_text('---\ntitle: Synthetic\ndescription: Counts\n---\n### 本次活动\n- **查看天气**：SYNTHETIC_LATER_WEATHER。')
            response_mode = 'aside_continuation'
            continued = generate_roles()
            assert len(continued['items']) == 3 and migration in continued['items']
            paper = next(item for item in continued['items'] if item['title'] == '阅读示例论文')
            assert paper['sourceMemories'] == [role_file.name], 'brief viewing extended an inactive task'
            other = next(item for item in continued['items'] if item['title'] == '期间的其他活动')
            assert other['sourceIncidental'][later.name] == [1]
            before = len(requests)
            generate_roles()
            assert len(requests) == before
            resumed = role_memories / '2020-01-01T00-20-00Z-ABCD-10min-memory-summary.md'
            resumed.write_text('---\ntitle: Synthetic\ndescription: Counts\n---\n### 本次活动\n- **继续阅读论文**：SYNTHETIC_PAPER_RESUMED。')
            response_mode = 'continue'
            returned = generate_roles()
            assert len(returned['items']) == 2 and migration in returned['items'], 'brief aside prevented task resumption'
            task = next(item for item in returned['items'] if resumed.name in item['sourceMemories'])
            assert task['sourceIncidental'][later.name] == [1]
            assert role_file.name in task['sourceMemories']
            assert 'SYNTHETIC_LATER_WEATHER' not in requests[-1].split('## 待整理的新增活动')[0]
            print('PASS: shared-source tasks, full continuation material, sibling preservation, failure retention, revision, and fixed mode')
            print('PASS: grouped task steps, separately attributed asides, brief interruption continuation, and unchanged task retention')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    main()
