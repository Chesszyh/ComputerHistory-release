#!/usr/bin/env python3
"""Exercise report/API/export and GitHub backup boundaries using synthetic local fixtures."""
import datetime
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

os.environ["COMPUTER_HISTORY_NOTIFICATIONS"] = "0"

binary = str(Path(sys.argv[1]).resolve())
calls = []
mode = 'ok'
fail_at = None
class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append(data)
        if mode == 'fail' or len(calls) == fail_at:
            self.send_response(503); self.end_headers(); return
        content = '' if mode == 'empty' else '## 主要工作\n完成合成任务。\n## 进展与产出\n合成结果。'
        result = {'choices': [{'message': {'content': content}, 'finish_reason': 'length' if mode == 'truncated' else 'stop'}],
                  'usage': {'prompt_tokens': 100, 'completion_tokens': 30, 'total_tokens': 130}}
        body = json.dumps(result).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass

with tempfile.TemporaryDirectory(prefix='report-test-') as directory:
    base = Path(directory); root = base/'data'; root.mkdir(); mem = root/'memories'; mem.mkdir()
    env = dict(os.environ)
    for key in ['DEEPSEEK_API_KEY','DEEPSEEK_BASE_URL','DEEPSEEK_MODEL']: env.pop(key, None)
    def run(*args, ok=True):
        p = subprocess.run([binary, *args, '--out', str(root)], env=env, capture_output=True, text=True, timeout=60)
        assert (p.returncode == 0) == ok, (args,p.returncode,p.stdout,p.stderr)
        return p
    def memory(day, content='合成活动。', generation='model'):
        file=mem/f'{day}T10-00-00Z-abcd-10min-memory-summary.md'
        file.write_text(f'---\ntitle: Synthetic\ndescription: summary\ngeneration: {generation}\napplications: []\n---\n## Memory summary\n### 本次活动\n{content}\n## Recording summary\n### 时序证据\nRAW PRIVATE\n## Citations\n/private/synthetic/events.jsonl\n')
        return file
    first=memory('2020-01-01')
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Model)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    (root/'model.json').write_text(json.dumps({'baseURL':f'http://127.0.0.1:{server.server_port}/v1','model':'synthetic-model','requiresAPIKey':False,'reasoningEffort':'none'}))
    try:
        run('report','--day','2020-01-01','--no-model')
        assert not calls
        run('report','--day','2020-01-01')
        assert len(calls)==1
        report=root/'reports/daily/2020-01-01.json';original=report.read_bytes()
        run('report','--day','2020-01-01');assert len(calls)==1
        run('export','--day','2020-01-01','--material','--file',str(base/'material.md'))
        material=(base/'material.md').read_text()
        assert '合成活动' in material and 'RAW PRIVATE' not in material and '/private/synthetic' not in material
        run('export','--day','2020-01-01','--format','txt','--file',str(base/'report.txt'))
        assert '## ' not in (base/'report.txt').read_text()
        for failure in ['fail','empty','truncated']:
            mode=failure
            run('report','--day','2020-01-01','--overwrite',ok=False)
            assert report.read_bytes()==original
        mode='ok'
        first.write_text(first.read_text().replace('合成活动。','新增来源结果。'))
        run('report','--day','2020-01-01');assert report.read_bytes()!=original
        run('report','--kind','weekly','--day','2020-01-01')
        assert (root/'reports/weekly/2019-12-30.json').exists()
        assert all(r['model']=='synthetic-model' and r['reasoning_effort']=='none' for r in calls)
        memory('2020-01-04','普通日报材料。'*5000)
        before=len(calls)
        run('report','--day','2020-01-04')
        assert len(calls)==before+1, 'ordinary daily material must use one request without a merge'
        memory('2020-01-02','👩🏽‍💻'*80000)
        before=len(calls);fail_at=before+2
        run('report','--day','2020-01-02',ok=False)
        assert not (root/'reports/daily/2020-01-02.json').exists()
        fail_at=None
        run('report','--day','2020-01-02')
        chunk_inputs=[r['messages'][1]['content'] for r in calls[before:]]
        assert chunk_inputs.count(chunk_inputs[0])==1, 'completed batch must be reused after retry'
        ledger=[json.loads(p.read_text()) for p in (root/'requests').glob('*.json')]
        assert {'daily','weekly'} <= {r['task'] for r in ledger}
        # Fake gh and redirect git transports to a local bare repository; all Git state transitions are real.
        bare=base/'remote.git'; realgit=shutil.which('git')
        subprocess.run([realgit,'init','--bare','--initial-branch=master',str(bare)],check=True,capture_output=True)
        tools=base/'bin';tools.mkdir();trace=base/'commands.log'
        env.update(PATH=str(tools)+os.pathsep+env['PATH'], REPORT_TEST_BARE=str(bare), REPORT_TEST_GIT=realgit, REPORT_TEST_TRACE=str(trace))
        (tools/'gh').write_text('''#!/usr/bin/env python3
import os,subprocess,sys
from pathlib import Path
args=sys.argv[1:];bare=os.environ['REPORT_TEST_BARE'];git=os.environ['REPORT_TEST_GIT']
with open(os.environ['REPORT_TEST_TRACE'],'a') as f:f.write('gh '+repr(args)+'\\n')
if args[:2]==['repo','clone']:
 subprocess.run([git,'clone',bare,args[3]],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 subprocess.run([git,'remote','set-url','origin','https://github.com/'+args[2]+'.git'],cwd=args[3],check=True)
elif '/git/ref/' in args[1]:
 print(subprocess.check_output([git,'--git-dir',bare,'rev-parse','HEAD'],text=True).strip())
else: print('false' if os.environ.get('REPORT_TEST_PUBLIC') else 'true')
''')
        (tools/'git').write_text('''#!/usr/bin/env python3
import os,sys
args=sys.argv[1:]
with open(os.environ['REPORT_TEST_TRACE'],'a') as f:f.write('git '+repr(args)+'\\n')
if 'fetch' in args:
 args=['fetch',os.environ['REPORT_TEST_BARE'],'+refs/heads/*:refs/remotes/origin/*']
elif 'push' in args:
 if os.environ.get('REPORT_TEST_PUSH_FAIL'):sys.exit('synthetic push failure')
 args=['push',os.environ['REPORT_TEST_BARE'],args[-1]]
os.execv(os.environ['REPORT_TEST_GIT'],[os.environ['REPORT_TEST_GIT']]+args)
''')
        for file in tools.iterdir():file.chmod(0o755)
        run('backup','--automatic');assert not trace.exists()
        run('backup','--repository','example/synthetic-private')
        env['REPORT_TEST_PUBLIC']='1';run('backup',ok=False)
        assert not (bare/'refs/heads/master').exists()
        del env['REPORT_TEST_PUBLIC']
        run('backup')
        status=json.loads((root/'backup-status.json').read_text());assert status['commit']
        files=subprocess.check_output([realgit,'--git-dir',str(bare),'ls-tree','-r','--name-only','HEAD'],text=True).splitlines()
        assert files and all(f.startswith(('archive/activities/','archive/daily/','archive/weekly/')) for f in files)
        assert not any('requests' in f or 'config' in f or 'work/' in f for f in files)
        count=trace.read_text();run('backup','--automatic');assert trace.read_text()==count
        memory('2020-01-03','new backup source')
        env['REPORT_TEST_PUSH_FAIL']='1';run('backup',ok=False)
        failed=json.loads((root/'backup-status.json').read_text())
        assert failed['error'] and failed['commit']==status['commit']
        del env['REPORT_TEST_PUSH_FAIL']
        run('backup')
        assert json.loads((root/'backup-status.json').read_text())['commit']!=status['commit']
        first.unlink();run('backup')
        assert 'archive/activities/2020-01-01.md' in subprocess.check_output([realgit,'--git-dir',str(bare),'ls-tree','-r','--name-only','HEAD'],text=True)
        run('backup','--disable');count=trace.read_text();run('backup','--automatic');assert trace.read_text()==count
        assert json.loads((root/'backup.json').read_text())['enabled'] is False
        print('PASS: offline export, API daily/weekly, unchanged-source skip, failure preservation, batch retry, private-only backup, remote SHA, daily skip, disable, and archive retention')
    finally:server.shutdown()
