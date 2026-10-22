#!/usr/bin/env python3
"""Sealed segments must bypass periodic waits and background report generation."""
import datetime
import http.server
import re
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
binary=str(Path(sys.argv[1]).resolve())
os.environ['COMPUTER_HISTORY_NOTIFICATIONS']='0'
report_started=threading.Event();release=threading.Event()
class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if '撰写中文日报' in data['messages'][0]['content']:
            report_started.set();release.wait(12)
        numbers = re.findall(r'### 来源 (S\d+)', data['messages'][1]['content'])
        content=f'## [{",".join(numbers)}] 合成活动\n合成摘要。' if numbers else '### 本次活动\n合成任务取得进展。'
        body=json.dumps({'choices':[{'message':{'content':content},'finish_reason':'stop'}],'usage':{'prompt_tokens':10,'completion_tokens':10,'total_tokens':20}}).encode()
        try:self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
    def log_message(self,*_):pass

def segment(root,sid):
    directory=root/'segments'/sid;directory.mkdir(parents=True,exist_ok=True)
    stamp=datetime.datetime.strptime(sid,'%Y-%m-%dT%H-%M-%SZ').isoformat()+'Z'
    (directory/'events.jsonl').write_text(json.dumps({'id':1,'timestamp':stamp,'kind':'window.changed','app':{'name':'Synthetic','bundleIdentifier':'test.app'}})+'\n')
    (directory/'metadata.json').write_text('{}')
def ready(root,sid):return bool(list((root/'memories').glob(sid+'-*-10min-memory-summary.md')))
def launch(root,offline):
    (root/'control.json').write_text(json.dumps({'recording':False,'summarizing':True}))
    (root/'config.json').write_text(json.dumps({'retention':{'maxAgeDays':0}}))
    log=(root/'test.log').open('w')
    p=subprocess.Popen([binary,'supervise','--out',str(root),'--memorize-interval','8']+(['--no-model'] if offline else []),stdout=log,stderr=log,start_new_session=True)
    return p,log
def stop(root,p,log):
    release.set();subprocess.run([binary,'--stop','--out',str(root)],capture_output=True)
    p.wait(timeout=8);log.close()
with tempfile.TemporaryDirectory(prefix='scheduling-test-') as d:
    root=Path(d);p,log=launch(root,True)
    try:
        time.sleep(1.5);sid='2020-01-01T00-00-00Z';segment(root,sid);start=time.monotonic()
        while time.monotonic()-start<3 and not ready(root,sid):time.sleep(.05)
        elapsed=time.monotonic()-start
        assert ready(root,sid),(elapsed,(root/'test.log').read_text())
        print(f'PASS: new sealed segment summarized in {elapsed:.2f}s with an 8s periodic interval')
    finally:stop(root,p,log)
with tempfile.TemporaryDirectory(prefix='scheduling-background-') as d:
    root=Path(d);server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Model)
    threading.Thread(target=server.serve_forever,daemon=True).start();release.clear()
    (root/'model.json').write_text(json.dumps({'baseURL':f'http://127.0.0.1:{server.server_port}/v1','model':'synthetic','requiresAPIKey':False,'reasoningEffort':'none'}))
    segment(root,'2020-01-01T00-00-00Z');p,log=launch(root,False)
    try:
        assert report_started.wait(10),(root/'test.log').read_text()
        sid='2020-01-02T00-00-00Z';segment(root,sid);start=time.monotonic()
        while time.monotonic()-start<3 and not ready(root,sid):time.sleep(.05)
        elapsed=time.monotonic()-start
        assert ready(root,sid),(elapsed,(root/'test.log').read_text())
        assert not release.is_set()
        print(f'PASS: sealed segment summarized in {elapsed:.2f}s while a report HTTP request remains blocked')
    finally:stop(root,p,log);server.shutdown();server.server_close()
