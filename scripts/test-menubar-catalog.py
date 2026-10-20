#!/usr/bin/env python3
"""Run the native catalog panel against a synthetic local models endpoint."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading

calls=[]
class Catalog(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        calls.append((self.path,self.headers.get('Authorization'),self.headers.get('Content-Length')))
        body=json.dumps({'data':[
            {'id':'synthetic-alpha','name':'Synthetic Alpha','effort':{'supported_levels':['vendor-low','vendor-max'],'default_level':'vendor-low'}},
            {'id':'synthetic-beta'}]}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*_): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Catalog)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    env=dict(os.environ,COMPUTER_HISTORY_CATALOG_TEST_URL=f'http://127.0.0.1:{server.server_port}/v1')
    subprocess.run(['bash','scripts/test-menubar-panel.sh','scripts/test-menubar-catalog.swift'],cwd=Path(__file__).resolve().parent.parent,env=env,check=True)
    assert calls==[('/v1/models',None,None)],calls
finally:
    server.shutdown();server.server_close()
