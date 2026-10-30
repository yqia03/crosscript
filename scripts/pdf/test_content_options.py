#!/usr/bin/env python3
"""T20 content matrix: pinned real engine, synthetic PDFs, local bounded service."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import pymupdf

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / '.scratch/t20/content-options'
RUN.mkdir(parents=True, exist_ok=True)

def text_page(doc, number):
    page = doc.new_page(width=420, height=595)
    page.insert_text((40, 70), f'PAGE-{number} Research material', fontsize=18)
    page.insert_textbox((40, 100, 380, 190), 'The translation application preserves the original research material and creates an independent result for each request.', fontsize=12)
    return page

with pymupdf.open() as doc:
    text_page(doc, 1)
    doc.save(RUN / 'ordinary.pdf')
    raster = doc[0].get_pixmap(matrix=pymupdf.Matrix(1.5, 1.5)).tobytes('png')
for kind in ['scan', 'ocr-layer', 'mixed']:
    with pymupdf.open() as doc:
        for number in range(1, 6):
            if kind == 'mixed' and number <= 3:
                text_page(doc, number)
                continue
            page = doc.new_page(width=420, height=595)
            page.insert_image(page.rect, stream=raster)
            if kind == 'ocr-layer':
                page.insert_text((40, 70), f'PAGE-{number} Research material', fontsize=18, render_mode=3)
                page.insert_textbox((40, 100, 380, 190), 'The translation application preserves the original research material and creates an independent result for each request.', fontsize=12, render_mode=3)
        doc.save(RUN / (kind + '.pdf'))
with pymupdf.open() as doc:
    page = doc.new_page(width=420, height=595)
    page.insert_text((40, 55), 'Table of measured results', fontsize=18)
    rows = [('Measurement', 'Result'), ('Network latency', 'Twenty milliseconds'), ('Cache capacity', 'One hundred entries'), ('Translation quality', 'Human reviewed')]
    for index, (left, right) in enumerate(rows):
        y = 100 + index * 45
        page.insert_text((45, y + 25), left, fontsize=10)
        page.insert_text((220, y + 25), right, fontsize=10)
        page.draw_line((40, y), (390, y))
    page.draw_line((40, 280), (390, 280))
    for x in [40, 210, 390]: page.draw_line((x, 100), (x, 280))
    doc.save(RUN / 'table.pdf')

class Service(BaseHTTPRequestHandler):
    calls = []
    def log_message(self, *args): pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        prompt = request['messages'][-1]['content']
        self.calls.append(prompt)
        def translate(text):
            return '中文译文：独立保存研究资料。' + ' '.join(dict.fromkeys(re.findall(r'PAGE-\d', str(text))))
        if '## Here is the input:' in prompt:
            rows = json.loads(prompt.split('## Here is the input:')[-1].strip())
            content = json.dumps([{'id': row['id'], 'output': translate(row)} for row in rows], ensure_ascii=False)
        else: content = translate(prompt)
        body = json.dumps({'id': 'controlled', 'object': 'chat.completion', 'created': 0, 'model': request['model'], 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': content}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 120}}, ensure_ascii=False).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

server = ThreadingHTTPServer(('127.0.0.1', 0), Service)
threading.Thread(target=server.serve_forever, daemon=True).start()
cases = [
    ('ordinary', 'ordinary', {}, 'finished'),
    ('scan-detect', 'scan', {}, 'scannedDocument'),
    ('scan-forced', 'scan', {'ocr_workaround': True, 'skip_scanned_detection': True}, 'noExtractableText'),
    ('ocr-forced', 'ocr-layer', {'ocr_workaround': True, 'skip_scanned_detection': True}, 'finished'),
    ('ocr-auto', 'ocr-layer', {'auto_enable_ocr_workaround': True}, 'finished'),
    ('mixed', 'mixed', {}, 'finished'),
    ('table-graphics', 'table', {}, 'finished'),
    ('table-no-graphics', 'table', {'enable_graphic_element_process': False}, 'finished'),
    ('minimum-length', 'ordinary', {'min_text_length': 1000}, 'finished'),
    ('typeset-local', 'ordinary', {'skip_translation': True}, 'finished'),
    ('parse-local', 'ordinary', {'only_parse_generate_pdf': True, 'watermark_output_mode': 'no_watermark'}, 'finished'),
    ('scan-parse-local', 'scan', {'only_parse_generate_pdf': True, 'watermark_output_mode': 'no_watermark'}, 'finished'),
    ('parse-both-watermarks', 'ordinary', {'only_parse_generate_pdf': True, 'watermark_output_mode': 'both'}, 'configuration'),
]
for name, fixture, options, expected in cases:
    if os.environ.get('PDF_TEST_CASE') and name not in os.environ['PDF_TEST_CASE'].split(','): continue
    Service.calls.clear()
    local = options.get('skip_translation') or options.get('only_parse_generate_pdf')
    payload = {'protocol': 1, 'inputFile': str(RUN / (fixture + '.pdf')), 'outputDirectory': str(RUN / name), 'workingDirectory': str(RUN / (name + '-working')), 'cacheDirectory': os.environ['PDF_TEST_CACHE'], 'controlledLoopback': True, 'maximumRequests': 30, 'direction': 'englishToChinese', 'apiKey': '' if local else 'CONTROLLED', 'options': {'auto_extract_glossary': False, 'no_mono': True, 'qps': 4, 'ignore_cache': True, 'enable_graphic_element_process': True} | options}
    if not local: payload['provider'] = {'profileID': 'content-probe', 'baseURL': f'http://127.0.0.1:{server.server_port}/v1', 'model': 'controlled'}
    started = time.monotonic()
    run = subprocess.run([sys.executable, '-u', str(ROOT / 'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py')], input=json.dumps(payload), capture_output=True, text=True, timeout=120)
    (RUN / (name + '-events.jsonl')).write_text(run.stdout)
    (RUN / (name + '-requests.json')).write_text(json.dumps(Service.calls, ensure_ascii=False, indent=2) + '\n')
    events = [json.loads(line) for line in run.stdout.splitlines()]
    final = events[-1] if events else {'stderr': run.stderr}
    outcome = final.get('code', final.get('type'))
    facts = {}
    for output in final.get('outputs', []):
        if output['kind'] == 'glossaryCSV': continue
        with pymupdf.open(output['path']) as doc:
            texts = [page.get_text() for page in doc]
            facts[output['kind']] = {'pages': len(doc), 'text': texts, 'images': [len(page.get_images()) for page in doc]}
            doc[0].get_pixmap().save(RUN / (name + '-' + output['kind'] + '.png'))
            if name == 'mixed': doc[3].get_pixmap().save(RUN / (name + '-scanned-page.png'))
    record = {'case': name, 'options': options, 'requests': len(Service.calls), 'outcome': outcome, 'expected': expected, 'seconds': round(time.monotonic() - started, 3), 'contentReport': final.get('contentReport'), 'outputs': facts, 'realEngine': True, 'service': 'controlled localhost' if not local else 'none; no provider or credential supplied', 'costUSD': 0}
    (RUN / (name + '-result.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: record[k] for k in ['case', 'requests', 'outcome', 'expected', 'seconds', 'contentReport']}), flush=True)
    if os.environ.get('PDF_TEST_DISCOVER'): continue
    assert outcome == expected, (name, final)
    if local: assert not Service.calls and all('中文译文' not in text for output in facts.values() for text in output['text'])
    if outcome == 'finished':
        assert facts
        assert final['contentReport']['sourcePageCount'] == (5 if fixture in ['scan', 'ocr-layer', 'mixed'] else 1)
        if name == 'mixed': assert final['contentReport']['pagesWithoutExtractableText'] == 2
        if name == 'minimum-length': assert not Service.calls
        if not local and name != 'minimum-length': assert any('中文译文' in text for output in facts.values() for text in output['text'])
server.shutdown()
