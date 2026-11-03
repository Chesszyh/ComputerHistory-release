#!/usr/bin/env python3
"""Compare explicitly selected request materials without rewriting summaries."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--group-id', required=True)
    p.add_argument('--helper', type=Path, required=True)
    p.add_argument('--requests', type=Path, nargs='+', required=True)
    p.add_argument('--profile', action='append', required=True, help='model:reasoning_effort:output_budget')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--timeout', type=float, default=180)
    args = p.parse_args()
    groups = json.loads((args.root / 'model.json').read_text())['groups']
    group = next(g for g in groups if g['id'] == args.group_id)
    key = None
    if group.get('requiresAPIKey', True):
        result = subprocess.run([str(args.helper)], input=json.dumps({'operation': 'load', 'root': str(args.root.resolve()), 'groupID': args.group_id, 'fallback': False}), text=True, capture_output=True, check=True)
        key = json.loads(result.stdout).get('key')
        if not key:
            raise ValueError('Selected model group has no saved key.')
    args.out.mkdir(parents=True, exist_ok=False)
    profiles = []
    for profile in args.profile:
        model, effort, budget = profile.rsplit(':', 2)
        profiles.append((model, effort, int(budget)))
    url = group['baseURL'].rstrip('/') + '/chat/completions'
    for source in args.requests:
        material = json.loads(source.read_text())
        for index, (model, effort, budget) in enumerate(profiles):
            payload = {'model': model, 'messages': [{'role': 'system', 'content': material['system']}, {'role': 'user', 'content': material['input']}], 'reasoning_effort': effort}
            payload['max_completion_tokens' if group.get('requestStyle') == 'reasoning' else 'max_tokens'] = budget
            headers = {'Content-Type': 'application/json'}
            if key:
                headers['Authorization'] = 'Bearer ' + key
            record = {'source': str(source.resolve()), 'task': material['task'], 'model': model, 'effort': effort, 'budget': budget}
            started = time.monotonic()
            try:
                request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
                with urllib.request.urlopen(request, timeout=args.timeout) as response:
                    result = json.load(response)
                choice = result['choices'][0]
                output = choice['message'].get('content') or ''
                record.update(output=output, usage=result.get('usage'), finishReason=choice.get('finish_reason'))
                if material['task'] == 'narrative-grouping' or (material['task'] == 'narrative' and '只输出 JSON' in material['system']):
                    try:
                        parsed = json.loads(output)
                        record['formatValid'] = isinstance(parsed.get('groups'), list) if material['task'] == 'narrative-grouping' else bool(parsed.get('title') and parsed.get('summary'))
                        if material['task'] == 'narrative-grouping' and record['formatValid']:
                            groups = parsed['groups']
                            expected = re.findall(r'^#### 活动 (S\d+\.A\d+)$', material['input'], re.M)
                            record['ownershipValid'] = bool(groups) and [ref for g in groups for ref in g.get('references', [])] == expected and all(not g.get('continuesPrevious') or (i == 0 and '## 紧邻且可续接的 P1' in material['input']) for i, g in enumerate(groups))
                    except (ValueError, AttributeError):
                        record['formatValid'] = False
                else:
                    record['formatValid'] = bool(output.strip()) and choice.get('finish_reason') != 'length'
            except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as error:
                record['error'] = type(error).__name__
            record['seconds'] = round(time.monotonic() - started, 3)
            (args.out / (source.stem + '-' + str(index) + '.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2))
            print(json.dumps({k: v for k, v in record.items() if k not in ['output', 'source']}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
