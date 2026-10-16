#!/usr/bin/env python3
"""生成菜单交互验收用合成数据；目标目录必须尚不存在。"""
import argparse
import datetime as dt
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--large', action='store_true', help='生成约 1.5 GiB 事件，否则仅生成小数据组')
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
memories = args.out / 'memories'
memories.mkdir()
start = dt.datetime(2026, 10, 16, tzinfo=dt.timezone.utc)
event = {'id': 1, 'timestamp': start.isoformat(), 'kind': 'window.changed',
         'app': {'name': 'Fixture', 'bundleIdentifier': 'com.example.fixture'},
         'window': {'title': 'Synthetic ' + 'x' * 4096}}
line = (json.dumps(event) + '\n').encode()
repeats = 13_107_200 // len(line) if args.large else 2
block = line * repeats
names = []
for i in range(125):
    at = start + dt.timedelta(minutes=10 * i)
    segment_id = at.strftime('%Y-%m-%dT%H-%M-%SZ')
    if i < 120:
        segment = args.out / 'segments' / segment_id
        segment.mkdir(parents=True)
        (segment / 'events.jsonl').write_bytes(block)
        if i < 119:
            (segment / 'metadata.json').write_text(json.dumps({'eventCount': repeats}))
    name = f'{segment_id}-1234-10min-memory-summary.md'
    names.append(name)
    (memories / name).write_text(
        f'---\ntitle: 合成记录 {i}\ndescription: 用于菜单交互测试的合成摘要 {i}\n'
        'applications: [com.apple.TextEdit]\n---\n## Recording\n### 合成详情\n' + '合成测试内容。' * 400)
items = [{'id': f'fixture-{i}', 'timestamp': (start + dt.timedelta(minutes=10*i)).isoformat(),
          'title': f'合成叙述 {i}', 'summary': '用于展开、滚动和详情测试。',
          'apps': ['com.apple.TextEdit'], 'sourceMemories': [names[i]]} for i in range(72)]
(args.out / 'narrative.json').write_text(json.dumps({'generatedAt': start.isoformat(), 'items': items}))
print(json.dumps({'segments': 120, 'bytes': len(block) * 120, 'memories': 125, 'narratives': 72}))
