#!/usr/bin/env python3
"""Validate per-request fallback routing with local synthetic HTTP servers."""
import http.server
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
calls=[]
primary='ok'
secondary='ok'
class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model=data['model'];mode=secondary if model=='synthetic-fallback' else primary
        calls.append((data,self.headers.get('Authorization')))
        if mode=='timeout':time.sleep(2)
        if mode=='redirect':self.send_response(307);self.send_header('Location', '/redirect-target');self.end_headers();return
        if mode=='http':self.send_response(503);self.end_headers();return
        if mode=='malformed':body=b'{"broken":true}'
        else:
            text='' if mode=='empty' else '### 本次活动\n'+('Fallback synthetic result.' if model=='synthetic-fallback' else 'Primary synthetic result.')
            body=json.dumps({'choices':[{'message':{'content':text},'finish_reason':'length' if mode=='truncated' else 'stop'}],
                             'usage':{'prompt_tokens':100,'completion_tokens':20,'total_tokens':120}}).encode()
        if mode=='keepalive':
            try:
                self.send_response(200);self.send_header('Content-Length',str(len(body)+20));self.end_headers()
                for _ in range(20):self.wfile.write(b' ');self.wfile.flush();time.sleep(.15)
                self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError):pass
            return
        try:self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
    def log_message(self,*_):pass
with tempfile.TemporaryDirectory(prefix='fallback-test-') as d:
    root=Path(d);server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Model)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    sid='2020-01-01T00-00-00Z';segment=root/'segments'/sid;segment.mkdir(parents=True)
    (segment/'events.jsonl').write_text(json.dumps({'id':1,'kind':'window.changed','timestamp':'2020-01-01T00:00:01Z','app':{'name':'Synthetic','bundleIdentifier':'test.app'}})+'\n')
    (segment/'metadata.json').write_text(json.dumps({'id':sid,'startedAt':'2020-01-01T00:00:00Z','endedAt':'2020-01-01T00:00:01Z','eventCount':1,'suppressedEventCount':0,'eventsPath':str(segment/'events.jsonl')}))
    config={'baseURL':f'http://127.0.0.1:{server.server_port}/v1','model':'synthetic-primary','requiresAPIKey':True,
            'reasoningEffort':'medium','requestStyle':'reasoning','timeoutSeconds':1,
            'fallback':{'baseURL':f'http://127.0.0.1:{server.server_port}/v1','model':'synthetic-fallback',
                        'requiresAPIKey':True,'reasoningEffort':'none','timeoutSeconds':3}}
    env=dict(os.environ,DEEPSEEK_API_KEY='synthetic-primary-key',COMPUTER_HISTORY_FALLBACK_API_KEY='synthetic-fallback-key')
    def save(): (root/'model.json').write_text(json.dumps(config))
    def run(ok=True):
        p=subprocess.run([binary,'memorize','--out',d,'--segment',sid,'--overwrite'],env=env,capture_output=True,text=True,timeout=15)
        assert (p.returncode==0)==ok,p.stderr
        return next((root/'memories').glob('*10min-memory-summary.md')).read_text()
    try:
        save();out=run();assert len(calls)==1 and 'Primary synthetic result' in out
        assert calls[0][1]=='Bearer synthetic-primary-key'
        assert 'max_completion_tokens' in calls[0][0] and 'max_tokens' not in calls[0][0] and 'temperature' not in calls[0][0]
        for failure in ['http','empty','truncated','malformed','timeout','keepalive','redirect']:
            primary=failure;start=len(calls);started=time.monotonic();out=run()
            if failure=="keepalive":assert time.monotonic()-started<2.5,"keepalive extended the wall-clock deadline"
            assert len(calls)==start+2 and 'Fallback synthetic result' in out,(failure,out)
            assert calls[-1][1]=='Bearer synthetic-fallback-key'
            assert calls[-1][0]['messages']==calls[-2][0]['messages']
            assert calls[-1][0]['reasoning_effort']=='none' and 'max_tokens' in calls[-1][0]
            health=json.loads((root/'model-health.json').read_text());assert health['usedFallback'] and not health.get('error')
        primary='ok';before=len(calls);run();assert len(calls)==before+1,'fallback must never change next request routing'
        primary='http';secondary='http';run(ok=False)
        health=json.loads((root/'model-health.json').read_text());assert health['error'] and health.get('lastNotification')
        ledger=[json.loads(p.read_text()) for p in (root/'requests').glob('*.json')];idx={r['id']:r for r in ledger}
        routed=[r for r in ledger if r.get('fallbackOf')];assert routed
        for r in routed:
            parent=idx[r['fallbackOf']]
            assert parent['status'] in ['failed','empty','truncated']
            assert parent['input']==r['input'] and parent['system']==r['system']
        assert all('Authorization' not in p.read_text() and 'synthetic-primary-key' not in p.read_text() for p in (root/'requests').glob('*.json'))
        primary='http';secondary='ok';config['fallback']['requiresAPIKey']=False;save();run();assert calls[-1][1] is None
        config['dailyBudget']=0;config['pricing']={'currency':'CNY','inputPerMillion':1,'cachedInputPerMillion':0,'outputPerMillion':1};save()
        before=len(calls);run(ok=False);assert len(calls)==before,'budget must not be bypassed through fallback'
        config.pop('dailyBudget');config.pop('pricing')
        fallback=config.pop('fallback')
        groups={'groups':[dict(config,id='first',name='First'),dict(fallback,id='second',name='Second')],
                'primaryGroupID':'first','fallbackGroupID':'second'}
        (root/'model.json').write_text(json.dumps(groups))
        before=len(calls);out=run();assert len(calls)==before+2 and 'Fallback synthetic result' in out
        assert calls[-2][1]=='Bearer synthetic-primary-key' and calls[-1][1] is None
        groups['primaryGroupID']='second';groups['fallbackGroupID']='first'
        (root/'model.json').write_text(json.dumps(groups))
        before=len(calls);out=run();assert len(calls)==before+1 and 'Fallback synthetic result' in out
        assert calls[-1][0]['model']=='synthetic-fallback' and calls[-1][1] is None
        groups['groups'][1].pop('reasoningEffort',None)
        (root/'model.json').write_text(json.dumps(groups))
        run();assert 'reasoning_effort' not in calls[-1][0], 'blank effort must use server default'
        groups['groups'][1]['reasoningEffort']='provider-custom-level'
        (root/'model.json').write_text(json.dumps(groups))
        run();assert calls[-1][0]['reasoning_effort']=='provider-custom-level'
        assert 'max_tokens' in calls[-1][0], 'standard parameter format must not disable reasoning effort'
        print('PASS: model-group selection and swap; primary-only success; HTTP, empty, truncated, malformed and timeout fallback; independent credentials; next request resets; total-failure health; linked ledger; keyless fallback; budget boundary')
    finally:server.shutdown();server.server_close()
