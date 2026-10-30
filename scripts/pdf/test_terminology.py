#!/usr/bin/env python3
"""T17: real locked BabelDOC with separate controlled HTTP targets. No real keys."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import pymupdf

parser = argparse.ArgumentParser()
parser.add_argument('--assets', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--same-names', action='store_true', help='Regression: different saved IDs share the same user-visible name')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
args.output.mkdir(parents=True, exist_ok=False)
source = args.output / 'original.pdf'
document = pymupdf.open()
page = document.new_page()
page.insert_text((60, 90), 'Latency and cache are important engineering terms.', fontsize=13)
page.insert_text((60, 120), 'Keep an independent copy of each translated result.', fontsize=13)
document.save(source)
document.close()
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
requests = []

class Controlled(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        expected = 'term-controlled-sentinel' if value['model'] == 'term-model' else 'primary-controlled-sentinel'
        assert self.headers.get('Authorization') == 'Bearer ' + expected
        requests.append(value)
        prompt = value['messages'][-1]['content']
        if value['model'] == 'term-model':
            content = json.dumps([{'src':'Latency','tgt':'延迟'},{'src':'cache','tgt':'缓存'}], ensure_ascii=False)
        else:
            content = '延迟与缓存是重要工程术语。每份译文保留独立副本。'
            if '## Here is the input:' in prompt:
                rows = json.loads(prompt.split('## Here is the input:')[-1].strip())
                content = json.dumps([{'id':row['id'],'output':content} for row in rows], ensure_ascii=False)
        body = json.dumps({'id':'controlled', 'object':'chat.completion', 'created':0, 'model':value['model'],
            'choices':[{'index':0,'message':{'role':'assistant','content':content},'finish_reason':'stop'}],
            'usage':{'prompt_tokens':100,'completion_tokens':40,'total_tokens':140}}, ensure_ascii=False).encode()
        self.send_response(200); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)

primary = ThreadingHTTPServer(('127.0.0.1', 0), Controlled)
terms = ThreadingHTTPServer(('127.0.0.1', 0), Controlled)
for server in (primary, terms): threading.Thread(target=server.serve_forever, daemon=True).start()
resources = {'glossaries':[
    {'id':'11111111-1111-4111-8111-111111111111','name':'Engineering','entries':[
        {'source':'Latency','target':'延迟','targetLanguage':'zh'},
        {'source':'Latency','target':'DoNotSendJapaneseOnly','targetLanguage':'ja'}]},
    {'id':'22222222-2222-4222-8222-222222222222','name':'Computing','entries':[{'source':'cache','target':'缓存'}]}]}
if args.same_names:
    for glossary in resources['glossaries']: glossary['name'] = 'Shared name'
summary=[]
try:
    for extraction in (False, True):
        name = 'extracted' if extraction else 'direct'
        run = args.output / name; run.mkdir()
        requests.clear()
        payload = {'protocol':1, 'inputFile':str(source), 'outputDirectory':str(run/'output'), 'workingDirectory':str(run/'working'),
            'cacheDirectory':str(args.assets), 'direction':'englishToChinese', 'controlledLoopback':True, 'maximumRequests':5,
            'provider':{'profileID':'primary-controlled','baseURL':f'http://127.0.0.1:{primary.server_port}/v1','model':'primary-model'},
            'apiKey':'primary-controlled-sentinel', 'resources':resources,
            'options':{'auto_extract_glossary':extraction,'save_auto_extracted_glossary':extraction,'no_mono':True,'ignore_cache':True,
                       'qps':1,'pool_max_workers':1,'term_pool_max_workers':1,
                       'custom_system_prompt':'WORKBENCH_PRESET: Use precise engineering prose.'}}
        if extraction:
            payload['termExtraction']={'provider':{'profileID':'term-controlled','baseURL':f'http://127.0.0.1:{terms.server_port}/v1','model':'term-model'},
                'apiKey':'term-controlled-sentinel','reasoning':'low'}
        started=time.monotonic()
        process=subprocess.run([sys.executable,'-u',str(root/'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py')],
            input=json.dumps(payload)+'\n',text=True,capture_output=True,timeout=120)
        events=[json.loads(line) for line in process.stdout.splitlines()]
        (run/'events.jsonl').write_text(process.stdout)
        (run/'requests.json').write_text(json.dumps(requests,ensure_ascii=False,indent=2))
        (run/'stderr.txt').write_text(process.stderr)
        assert process.returncode==0 and events[-1]['type']=='finished',events[-1:]
        assert 'controlled-sentinel' not in process.stdout+process.stderr
        request_text=json.dumps(requests,ensure_ascii=False)
        assert 'WORKBENCH_PRESET' in request_text
        assert 'DoNotSendJapaneseOnly' not in request_text
        if args.same_names:
            assert 'Shared name [id:11111111-1111-4111-8111-111111111111]' in request_text
            assert 'Shared name [id:22222222-2222-4222-8222-222222222222]' in request_text
        else: assert 'Engineering' in request_text and 'Computing' in request_text
        assert '延迟' in request_text and '缓存' in request_text
        if extraction:
            term_requests=[r for r in requests if r['model']=='term-model']
            assert term_requests and term_requests[0]['reasoning']=={'effort':'low'}
        else: assert all(r['model']=='primary-model' for r in requests)
        outputs=events[-1]['outputs']
        pdf=next(Path(x['path']) for x in outputs if x['kind']=='dual')
        with pymupdf.open(pdf) as output:
            assert output.page_count==1
            assert '缓存' in output[0].get_text()
            output[0].get_pixmap().save(run/'dual.png')
        if extraction:
            csv=next(Path(x['path']) for x in outputs if x['kind']=='glossaryCSV')
            assert 'Latency' in csv.read_text(encoding='utf-8-sig') and '延迟' in csv.read_text(encoding='utf-8-sig')
        (run/'requests.json').write_text(json.dumps(requests,ensure_ascii=False,indent=2))
        summary.append({'case':name,'seconds':round(time.monotonic()-started,3),'requestCount':len(requests),
            'engine':'0.6.4','twoNamedGlossariesDelivered':True,'sameNamedGlossaries':args.same_names,'customPromptDelivered':True,'separateCredentialTargets':extraction,
            'pdfReopened':True,'extractedCSV':extraction,'service':'controlled HTTP, not real provider','costUSD':0})
    assert hashlib.sha256(source.read_bytes()).hexdigest()==source_hash
finally:
    primary.shutdown(); terms.shutdown()
(args.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print(json.dumps(summary,ensure_ascii=False))
