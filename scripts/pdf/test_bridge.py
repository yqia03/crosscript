#!/usr/bin/env python3
"""Real engine bridge integration. Controlled local HTTP only; never reads keys."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from v4_probe import ControlledService, requests
ROOT=Path(__file__).resolve().parents[2]
BRIDGE=ROOT/'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py'
RUN=Path(os.environ.get('PDF_TEST_OUTPUT', str(ROOT/'.scratch/t15/bridge-test')))
RUN.mkdir(parents=True,exist_ok=True)
server=ThreadingHTTPServer(('127.0.0.1',0),ControlledService)
threading.Thread(target=server.serve_forever,daemon=True).start()
payload={'protocol':1,'cacheDirectory':os.environ['PDF_TEST_CACHE'],
    'inputFile':str(ROOT/'tests/fixtures/pdf/synthetic-one-page.pdf'),
    'outputDirectory':str(RUN/'output'),'workingDirectory':str(RUN/'working'),
    'direction':'englishToChinese','controlledLoopback':True,'maximumRequests':4,
    'provider':{'profileID':'bridge-probe','baseURL':f'http://127.0.0.1:{server.server_port}/v1','model':'controlled-v4'},
    'apiKey':'CONTROLLED_SENTINEL_NEVER_LOG','options':{'auto_extract_glossary':False,'no_mono':True,'qps':1}}
started=time.monotonic()
process=subprocess.run([sys.executable,'-u',str(BRIDGE)],input=json.dumps(payload),text=True,capture_output=True,timeout=90)
assert process.returncode==0,process.stdout
assert payload['apiKey'] not in process.stdout+process.stderr
messages=[json.loads(line) for line in process.stdout.splitlines()]
assert messages[-1]['type']=='finished',messages[-1]
assert sum(x['type']=='finished' for x in messages)==1
assert not any(x['type']=='failed' for x in messages)
assert 1<=messages[-1]['requestCount']<=4
assert messages[-1]['outputs'][0]['kind']=='dual'
import pymupdf
with pymupdf.open(messages[-1]['outputs'][0]['path']) as document:
    assert document.page_count==1
    assert '真实引擎验证' in document[0].get_text()
    document[0].get_pixmap().save(RUN/'bridge-dual.png')
summary={'engine':'0.6.4','bridge':1,'exitStatus':process.returncode,'seconds':round(time.monotonic()-started,3),
    'events':len(messages),'requests':messages[-1]['requestCount'],'apiKeyInOutput':False,'pdfReopened':True,'source':'controlled HTTP + real BabelDOC'}
(RUN/'success.json').write_text(json.dumps(summary,indent=2))
(RUN/'events.jsonl').write_text(process.stdout)
print(json.dumps(summary))
server.shutdown()

# Real engine receives a rate limit from a controlled target; no hidden retries.
from http.server import BaseHTTPRequestHandler
class RateLimit(BaseHTTPRequestHandler):
    calls=0
    def log_message(self,*args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        type(self).calls+=1
        body=b'{"error":{"message":"controlled quota","type":"rate_limit_error"}}'
        self.send_response(429);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=ThreadingHTTPServer(('127.0.0.1',0),RateLimit)
threading.Thread(target=server.serve_forever,daemon=True).start()
payload['provider']['baseURL']=f'http://127.0.0.1:{server.server_port}/v1'
payload['options']['ignore_cache']=True
payload['outputDirectory']=str(RUN/'failure')
process=subprocess.run([sys.executable,'-u',str(BRIDGE)],input=json.dumps(payload),text=True,capture_output=True,timeout=90)
events=[json.loads(line) for line in process.stdout.splitlines()]
assert process.returncode==1 and events[-1]=={'type':'failed','code':'rateLimited'},process.stdout
assert RateLimit.calls==1,RateLimit.calls
assert not any(event['type']=='finished' for event in events)
server.shutdown()
print(json.dumps({'rateLimit':True,'requests':RateLimit.calls,'noHiddenRetry':True,'exitStatus':process.returncode}))

# Kill a real in-flight engine after the same bounded TERM→KILL policy as native.
class SlowService(RateLimit):
    entered=threading.Event()
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        type(self).entered.set()
        time.sleep(30)
server=ThreadingHTTPServer(('127.0.0.1',0),SlowService)
threading.Thread(target=server.serve_forever,daemon=True).start()
payload['provider']['baseURL']=f'http://127.0.0.1:{server.server_port}/v1'
payload['outputDirectory']=str(RUN/'cancelled')
process=subprocess.Popen([sys.executable,'-u',str(BRIDGE)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
process.stdin.write(json.dumps(payload)+'\n');process.stdin.close()
assert SlowService.entered.wait(60),'Engine did not start request'
start=time.monotonic();process.terminate()
try: process.wait(timeout=2)
except subprocess.TimeoutExpired: process.kill();process.wait(timeout=5)
stdout=process.stdout.read()
assert process.poll() is not None and '"type":"finished"' not in stdout
assert Path(payload['inputFile']).exists()
server.shutdown()
print(json.dumps({'realEngineCancellation':True,'terminationStatus':process.returncode,'waitSeconds':round(time.monotonic()-start,3),'sourceRetained':True}))
