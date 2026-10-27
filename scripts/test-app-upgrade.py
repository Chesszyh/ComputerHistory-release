#!/usr/bin/env python3
"""A changed self-signed helper must fail silently; installer preservation must restore access."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

spec=importlib.util.spec_from_file_location('installer',Path(__file__).with_name('manage-install.py'))
i=importlib.util.module_from_spec(spec);spec.loader.exec_module(i)
app=Path(sys.argv[1]).resolve()
adhoc = '--adhoc' in sys.argv[2:]
def sign(bundle):
    if adhoc:
        for name,suffix in [('computer-history','cli'),('computer-history-menubar','menubar'),('computer-history-credentials','credentials')]:
            subprocess.run(['codesign','--force','--sign','-','--identifier','xyz.chesszyh.computer-history.'+suffix,str(bundle/'Contents/MacOS'/name)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign','-','--identifier','xyz.chesszyh.computer-history.menubar',str(bundle)],check=True,capture_output=True)
    else:
        subprocess.run(['local-codesign',str(bundle)],check=True,capture_output=True)
with tempfile.TemporaryDirectory(prefix='computer-history-app-upgrade-') as directory:
    base=Path(directory);old=base/'old.app';new=base/'new.app'
    shutil.copytree(app,old);shutil.copytree(app,new)
    if adhoc:sign(old)
    helper=i.app_program(old,'computer-history-credentials')
    changed=i.app_program(new,'computer-history-credentials')
    def request(operation,binary=helper,**extra):
        r=subprocess.run([str(binary)],input=json.dumps(dict(operation=operation,root=str(base/'history'),groupID='synthetic',**extra)),text=True,capture_output=True,timeout=10)
        return r.returncode,json.loads(r.stdout)
    original=helper.read_bytes()
    data=bytearray(changed.read_bytes());offset=32
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,offset)
        if command==0x1b:
            data[offset+8:offset+24]=os.urandom(16);break
        offset+=size
    else:raise AssertionError('missing LC_UUID')
    changed.write_bytes(data)
    if adhoc:sign(new)
    else:
        subprocess.run(['local-codesign','--identifier','xyz.chesszyh.computer-history.credentials',str(changed)],check=True,capture_output=True)
        sign(new)
    assert request('save',key='synthetic-upgrade-key')[0]==0
    try:
        denied=request('load',changed)
        assert denied[0]!=0,'changed helper unexpectedly bypassed the reproduced build-specific partition'
        i.preserve_helper(old,new)
        assert changed.read_bytes()==original
        subprocess.run(['codesign','--verify','--deep','--strict',str(new)],check=True,capture_output=True)
        assert request('load',changed)[1]['key']=='synthetic-upgrade-key'
    finally:assert request('remove')[0]==0
print('PASS: reproduced rebuild denial; installed helper preserved; new app seal valid; no authentication UI')
