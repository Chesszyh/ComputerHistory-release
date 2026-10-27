#!/usr/bin/env python3
"""Exercise ownership, isolated prose, task returns, and resumable failures locally."""
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
mode = 'separate'
fail_summary = False

class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global fail_summary
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        user = payload['messages'][-1]['content']
        system = payload['messages'][0]['content']
        grouping = '只决定归属，不撰写摘要' in system
        requests.append((grouping, user))
        if grouping:
            refs = re.findall(r'^#### 活动 (S\d+\.A\d+)$', user, re.M)
            groups = [dict(references=[ref], continuesPrevious=False, task=None) for ref in refs]
            if mode == 'link_prior':
                groups[0]['task'] = 'T1'
            if mode == 'return':
                groups[-1]['task'] = 'G1'
            if mode == 'continue' and '## 紧邻且可续接的 P1' in user:
                groups[0]['continuesPrevious'] = True
            if mode == 'invalid':
                groups = groups[:1]
            content = json.dumps(dict(groups=groups), ensure_ascii=False)
        elif '分组已确定' in user:
            if fail_summary and 'SYNTHETIC_B' in user:
                self.send_response(503); self.end_headers(); return
            content = json.dumps(dict(title='核对合成事项。', summary='核对合成材料及其结果。'), ensure_ascii=False)
        else:
            refs = re.findall(r'^### 来源 (S\d+)', user, re.M)
            content = '\n\n'.join(f'## [{ref}] 核对合成事项\n保留该时段的活动。' for ref in refs)
        body = json.dumps({'choices':[{'message':{'content':content},'finish_reason':'stop'}],
                           'usage':{'prompt_tokens':100,'completion_tokens':50,'total_tokens':150}}).encode()
        self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass

def main():
    global mode, fail_summary
    binary = str(Path(sys.argv[1]).resolve())
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Model)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='narrative-activities-') as directory:
            root = Path(directory); (root/'memories').mkdir()
            (root/'model.json').write_text(json.dumps(dict(baseURL=f'http://127.0.0.1:{server.server_port}', model='synthetic',requiresAPIKey=False)))
            env = dict(os.environ,COMPUTER_HISTORY_NOTIFICATIONS='0')
            def memory(minute, activities):
                file=root/'memories'/f'2020-01-01T00-{minute:02d}-00Z-ABCD-10min-memory-summary.md'
                file.write_text('---\ntitle: Synthetic\ndescription: Counts\n---\n### 本次活动\n'+activities)
                return file
            def generate(success=True, overwrite=False):
                result=subprocess.run([binary,'narrative','--out',str(root)]+(['--overwrite'] if overwrite else []),env=env,capture_output=True,text=True,timeout=30)
                assert (result.returncode==0)==success,result.stderr
                return json.loads((root/'narrative.json').read_text()) if (root/'narrative.json').exists() else None
            first=memory(0,'- **修改解析**：SYNTHETIC_A。\n- **交流**：SYNTHETIC_B。')
            original=first.read_bytes()
            fail_summary=True
            generate(success=False)
            assert not (root/'narrative.json').exists(), 'failed batch exposed partial replacement'
            assert len(requests)==3 and requests[0][0]
            assert 'SYNTHETIC_B' not in requests[1][1], 'task B contaminated task A prose'
            assert 'SYNTHETIC_A' not in requests[2][1], 'task A contaminated task B prose'
            before=len(requests); fail_summary=False
            grouped=generate()
            assert len(requests)==before+1, 'successful grouping/prose was charged again after retry'
            assert len(grouped['items'])==2
            assert len({i['taskID'] for i in grouped['items']})==2
            assert all(not i['title'].endswith('。') for i in grouped['items'])
            before=len(requests); generate()
            assert len(requests)==before, 'unchanged input caused inference'
            second=memory(10,'- **继续交流**：SYNTHETIC_B_NEXT。')
            mode='continue'; continued=generate()
            assert len(continued['items'])==2
            task=next(i for i in continued['items'] if second.name in i['sourceMemories'])
            assert first.name in task['sourceMemories'] and task['sourceActivities'][first.name]==[2]
            assert first.read_bytes()==original
            saved=(root/'narrative.json').read_bytes()
            first.write_text(first.read_text()+'\n- **查看预约**：SYNTHETIC_C。')
            mode='invalid'; generate(success=False)
            assert (root/'narrative.json').read_bytes()==saved
            mode='separate'; regenerated=generate()
            assert len({(name,n) for i in regenerated['items'] for name,ns in i['sourceActivities'].items() for n in ns})==4
            (root/'summary.json').write_text(json.dumps(dict(timelineMode='fixed10min')))
            fixed=generate(overwrite=True)
            assert len(fixed['items'])==2 and all(len(i['sourceMemories'])==1 for i in fixed['items'])
            # Return within one batch retains three appearances and a shared task identity.
            (root/'summary.json').write_text(json.dumps(dict(timelineMode='continuous')))
            first.write_text('---\ntitle: Synthetic\ndescription: Counts\n---\n### 本次活动\n- **解析**：SYNTHETIC_A。\n- **交流**：SYNTHETIC_B。')
            second.write_text('---\ntitle: Synthetic\ndescription: Counts\n---\n### 本次活动\n- **解析验证**：SYNTHETIC_A_RETURN。')
            mode='return'; returned=generate(overwrite=True)
            assert len(returned['items'])==3
            ordered=sorted(returned['items'],key=lambda i:(i['timestamp'],min(min(ns) for ns in i['sourceActivities'].values())))
            assert ordered[0]['taskID']==ordered[2]['taskID']!=ordered[1]['taskID']
            assert len(ordered[0]['sourceMemories'])==len(ordered[2]['sourceMemories'])==1
            legacy = json.loads((root/'narrative.json').read_text())
            for item in legacy['items']: item.pop('taskID',None)
            (root/'narrative.json').write_text(json.dumps(legacy))
            third=memory(20,'- **恢复此前事项**：SYNTHETIC_RESUME。')
            mode='link_prior'; associated=generate()
            latest=next(item for item in associated['items'] if third.name in item['sourceMemories'])
            assert sum(item.get('taskID')==latest['taskID'] for item in associated['items'])>=2, 'legacy task was not promoted when linked'
            mode='separate'
            original_cache=(root/'narrative.json').read_bytes()
            originals={p.name:p.read_bytes() for p in (root/'memories').glob('*.md')}
            preview=root/'preview'
            result=subprocess.run([binary,'narrative','--out',str(root),'--day','2020-01-01','--overwrite','--preview-out',str(preview)],env=env,capture_output=True,text=True,timeout=30)
            assert result.returncode==0,result.stderr
            assert (preview/'narrative.json').exists() and (preview/'before-narrative.json').exists()
            assert not (preview/'model.json').exists() and not (preview/'requests').exists(), 'preview must reuse source credentials and budget ledger'
            assert (root/'narrative.json').read_bytes()==original_cache
            assert all((root/'memories'/name).read_bytes()==data for name,data in originals.items())
            print('PASS: isolated ownership/prose, cached retry, adjacent continuation, task return, revisions, fixed mode, unchanged originals')
    finally:
        server.shutdown(); server.server_close()

if __name__=='__main__': main()
