#!/usr/bin/env python3
"""Real BabelDOC verification against a local, controlled OpenAI-compatible service.
This tests the PDF engine and HTTP integration; it is not a supplier-quality test.
"""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / '.scratch/t15/probe'
RUN.mkdir(parents=True, exist_ok=True)
import babeldoc.const as const
const.CACHE_FOLDER = Path(os.environ['PDF_TEST_CACHE'])
const.TIKTOKEN_CACHE_FOLDER = const.CACHE_FOLDER / 'tiktoken'
os.environ['TIKTOKEN_CACHE_DIR'] = str(const.TIKTOKEN_CACHE_FOLDER)

requests = []
class ControlledService(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(value)
        prompt = value['messages'][-1]['content']
        content = '真实引擎验证：原始资料保持独立，翻译结果可以重新打开。'
        if '## Here is the input:' in prompt:
            rows = json.loads(prompt.split('## Here is the input:')[-1].strip())
            content = json.dumps([{'id': row['id'], 'output': content} for row in rows], ensure_ascii=False)
        body = json.dumps({'id':'controlled', 'object':'chat.completion', 'created':0,
            'model':value['model'], 'choices':[{'index':0,'message':{'role':'assistant','content':content},'finish_reason':'stop'}],
            'usage':{'prompt_tokens':100,'completion_tokens':30,'total_tokens':130}}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

async def main():
    from generate_synthetic_fixture import write_fixture
    input_path = RUN / 'original.pdf'
    write_fixture(input_path)
    server = ThreadingHTTPServer(('127.0.0.1',0), ControlledService)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    from babeldoc.translator.translator import OpenAITranslator, set_translate_rate_limiter
    from babeldoc.format.pdf.translation_config import TranslationConfig, WatermarkOutputMode
    from babeldoc.format.pdf.high_level import do_translate, get_translation_stage
    from babeldoc.progress_monitor import ProgressMonitor
    from babeldoc.docvision.doclayout import DocLayoutModel
    translator = OpenAITranslator('en','zh', model='controlled-v4',base_url=f'http://127.0.0.1:{server.server_port}/v1',api_key='controlled-not-secret',ignore_cache=True)
    set_translate_rate_limiter(1)
    model = DocLayoutModel.load_onnx()
    config = TranslationConfig(translator=translator, input_file=input_path,lang_in='en',lang_out='zh', doc_layout_model=model,
        output_dir=RUN / 'output',working_dir=RUN / 'working', no_mono=False,no_dual=False,qps=1,pool_max_workers=1,
        auto_extract_glossary=False,watermark_output_mode=WatermarkOutputMode.NoWatermark)
    with (RUN/'events.jsonl').open('w') as stream:
        def progress(**event):
            serialized={key:value for key,value in event.items() if isinstance(value,(str,int,float,bool,type(None)))}
            stream.write(json.dumps(serialized, ensure_ascii=False)+'\n')
            stream.flush()
            print(json.dumps(serialized,ensure_ascii=False),flush=True)
        with ProgressMonitor(get_translation_stage(config), progress_change_callback=progress, finish_callback=lambda **event: None, cancel_event=threading.Event()) as monitor:
            finished = do_translate(monitor,config)
        progress(type="finish", mono=str(finished.mono_pdf_path), dual=str(finished.dual_pdf_path))
    server.shutdown()
    if not finished:
        raise RuntimeError('Engine did not return finished PDF outputs')
    import pymupdf
    evidence={'engine':'0.6.4','integration':'direct API probe v1','supplier':'controlled localhost HTTP', 'requests':len(requests),'outputs':[]}
    for label,path in [('original',input_path),('mono',finished.mono_pdf_path),('dual',finished.dual_pdf_path)]:
        with pymupdf.open(path) as doc:
            text='\n'.join(page.get_text() for page in doc)
            if label != 'original' and '真实引擎验证' not in text:
                raise RuntimeError('No translated text in generated '+label)
            doc[0].get_pixmap(matrix=pymupdf.Matrix(1,1)).save(RUN/(label+'.png'))
            evidence['outputs'].append({'kind':label,'path':str(path),'pages':len(doc),'sha256':hashlib.sha256(Path(path).read_bytes()).hexdigest(),'text':text})
    (RUN/'result.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2))
    (RUN/'requests.json').write_text(json.dumps(requests,ensure_ascii=False,indent=2))
    print(json.dumps(evidence,ensure_ascii=False))

if __name__=='__main__': asyncio.run(main())
