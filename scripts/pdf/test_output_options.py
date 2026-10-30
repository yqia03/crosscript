#!/usr/bin/env python3
"""T18 real-engine output matrix. Local controlled HTTP; no real provider keys."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import pymupdf

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / '.scratch/t18/output-options'
RUN.mkdir(parents=True, exist_ok=True)
source = RUN / 'three-pages.pdf'
with pymupdf.open() as doc:
    for number in range(1,4):
        page = doc.new_page(width=420,height=595)
        page.insert_text((42,75),f'PAGE-{number} Original heading',fontsize=18)
        page.insert_textbox((42,120,380,230),f'This original paragraph belongs to PAGE-{number}. The application keeps this material independent from generated translation results.',fontsize=12)
    doc.save(source)
class Service(BaseHTTPRequestHandler):
    calls=[]
    def log_message(self,*args):pass
    def do_POST(self):
        request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        prompt=request['messages'][-1]['content']
        self.calls.append(prompt)
        def translated(text):
            markers=re.findall(r'PAGE-\d',str(text))
            return '中文译文：原始资料保持独立。' + ' '.join(dict.fromkeys(markers))
        if '## Here is the input:' in prompt:
            rows=json.loads(prompt.split('## Here is the input:')[-1].strip())
            content=json.dumps([{'id':row['id'],'output':translated(row)} for row in rows],ensure_ascii=False)
        else:content=translated(prompt)
        body=json.dumps({'id':'controlled','object':'chat.completion','created':0,'model':request['model'],'choices':[{'index':0,'message':{'role':'assistant','content':content},'finish_reason':'stop'}],'usage':{'prompt_tokens':100,'completion_tokens':20,'total_tokens':120}},ensure_ascii=False).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=ThreadingHTTPServer(('127.0.0.1',0),Service)
threading.Thread(target=server.serve_forever,daemon=True).start()
cache=os.environ['PDF_TEST_CACHE']
cases=[
 ('default-dual',{}, {'dual':3}),
 ('selected-mono-keep-others',{'pages':'2','no_mono':False,'no_dual':True}, {'mono':3}),
 ('selected-both-alternating-first',{'pages':'2-3','only_include_translated_page':True,'no_mono':False,'no_dual':False,'use_alternating_pages_dual':True,'dual_translate_first':True,'watermark_output_mode':'no_watermark'}, {'mono':2,'dual':4}),
 ('side-by-side-translation-first',{'dual_translate_first':True,'pages':'1'}, {'dual':3}),
 ('selected-parts-both-watermarks',{'pages':'2-3','only_include_translated_page':True,'no_mono':False,'max_pages_per_part':1,'watermark_output_mode':'both'}, {'mono':2,'dual':2,'monoNoWatermark':2,'dualNoWatermark':2}),
 ('parts-both-watermarks',{'no_mono':False,'max_pages_per_part':1,'watermark_output_mode':'both'}, {'mono':3,'dual':3,'monoNoWatermark':3,'dualNoWatermark':3})]
for name,options,expected in cases:
    if os.environ.get('PDF_TEST_CASE') and os.environ['PDF_TEST_CASE'] != name: continue
    Service.calls.clear()
    payload={'protocol':1,'inputFile':str(source),'outputDirectory':str(RUN/name),'workingDirectory':str(RUN/(name+'-working')),'cacheDirectory':cache,'controlledLoopback':True,'maximumRequests':30,'direction':'englishToChinese','provider':{'profileID':'output-probe','baseURL':f'http://127.0.0.1:{server.server_port}/v1','model':'controlled'},'apiKey':'CONTROLLED','options':{}}
    payload['options']={'auto_extract_glossary':False,'no_mono':True,'qps':4,'ignore_cache':True}|options
    run=subprocess.run([sys.executable,'-u',os.environ.get('PDF_TEST_BRIDGE',str(ROOT/'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py'))],input=json.dumps(payload),capture_output=True,text=True,timeout=120)
    events=[json.loads(line) for line in run.stdout.splitlines()]
    (RUN/(name+'-events.jsonl')).write_text(run.stdout)
    assert run.returncode==0 and events[-1]['type']=='finished',(name,run.stdout)
    outputs={x['kind']:x['path'] for x in events[-1]['outputs']}
    assert set(outputs)==set(expected),(name,outputs)
    facts={}
    for kind,path in outputs.items():
        with pymupdf.open(path) as doc:
            assert len(doc)==expected[kind],(name,kind,len(doc))
            texts=[page.get_text() for page in doc]
            facts[kind]={'pages':len(doc),'sizes':[[p.rect.width,p.rect.height] for p in doc],'text':texts}
            if name=='default-dual':
                assert all(p.rect.width==840 for p in doc)
                assert any('Original heading' in b[4] and b[0]<420 for b in doc[0].get_text('blocks'))
                assert any('中文译文' in b[4] and b[0]>420 for b in doc[0].get_text('blocks'))
            if name=='side-by-side-translation-first':
                assert any('Original heading' in b[4] and b[0]>420 for b in doc[0].get_text('blocks'))
                assert any('中文译文' in b[4] and b[0]<420 for b in doc[0].get_text('blocks'))
            if name=='selected-parts-both-watermarks':
                assert all('PAGE-1' not in text for text in texts)
                assert all(f'PAGE-{i+2}' in text for i,text in enumerate(texts))
            if name=='selected-mono-keep-others':
                assert '中文译文' not in texts[0] and '中文译文' in texts[1] and '中文译文' not in texts[2]
            if name=='selected-both-alternating-first' and kind=='dual':
                assert all('中文译文' in texts[i] for i in [0,2]) and all('Original heading' in texts[i] for i in [1,3])
                assert all('PAGE-1' not in text for text in texts)
            if name=='parts-both-watermarks': assert all(f'PAGE-{i+1}' in text for i,text in enumerate(texts))
            if name.endswith('both-watermarks'):
                assert ('BabelDOC' in texts[0]) == (not kind.endswith('NoWatermark'))
                assert all('BabelDOC' not in text for text in texts[1:])
            doc[0].get_pixmap().save(RUN/(name+'-'+kind+'.png'))
    record={'case':name,'options':options,'requests':len(Service.calls),'outputs':facts,'realEngine':True,'service':'controlled localhost','costUSD':0}
    (RUN/(name+'-result.json')).write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'case':name,'requests':len(Service.calls),'pages':{k:v['pages'] for k,v in facts.items()},'verified':True}),flush=True)
server.shutdown()
