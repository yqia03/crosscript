#!/usr/bin/env python3
"""T21 real font/formula/layout matrix. Local controlled service; no real keys."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import pymupdf
from engine_test_support import ControlledService

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / '.scratch/t21/layout-options'; RUN.mkdir(parents=True, exist_ok=True)
CACHE = Path(os.environ['PDF_TEST_CACHE'])
SOURCE = RUN / 'complex-layout.pdf'
with pymupdf.open() as doc:
    page = doc.new_page(width=595, height=842)
    page.insert_text((40, 55), 'Research layout and formula study', fontname='hebo', fontsize=19)
    page.insert_font(fontname='SourceChinese', fontfile=str(CACHE / 'fonts/SourceHanSerifCN-Regular.ttf'))
    page.insert_text((40, 88), '中英混排：公式与研究资料', fontname='SourceChinese', fontsize=15)
    for x in [40, 315]:
        page.insert_text((x, 108), 'Mixed ', fontname='tiro', fontsize=12)
        page.insert_text((x+34, 108), 'bold ', fontname='tibo', fontsize=12)
        page.insert_text((x+63, 108), 'italic words', fontname='tiit', fontsize=12)
        page.insert_textbox((x, 120, x + 240, 220), 'The research paper contains a bold heading and an italic sentence. Its source material must remain independent from the translated output.', fontname='tiro', fontsize=12)
        page.insert_text((x, 235), 'Important emphasis', fontname='tibi', fontsize=13)
        page.insert_text((x, 265), 'Energy relation:', fontsize=12)
        page.insert_text((x, 292), 'E = mc^2 + a/b', fontname='cour', fontsize=14)
        page.insert_text((x, 335), 'A short line.', fontsize=12)
        page.insert_text((x, 355), 'This paragraph continues across lines.', fontsize=12)
        page.insert_text((x, 375), 'Another short.', fontsize=12)
        page.draw_line((x, 410), (x + 220, 410), color=(0, 0, 1), width=1)
        for y in [450, 490, 530]: page.draw_line((x, y), (x + 220, y))
        for col in [x, x+100, x+220]: page.draw_line((col, 450), (col, 530))
        page.insert_text((x+4, 475), 'Method', fontsize=11); page.insert_text((x+105, 475), 'Observation', fontsize=11)
        page.insert_text((x+4, 515), 'Baseline', fontsize=11); page.insert_text((x+105, 515), 'Preserved', fontsize=11)
    with pymupdf.open() as form:
        fp = form.new_page(width=200, height=80); fp.draw_rect((10,10,190,70), color=(1,0,0), fill=(1,0.95,0.95)); fp.insert_text((20,45),'Embedded form object',fontsize=11)
        page.show_pdf_page(pymupdf.Rect(40,570,240,650), form, 0)
    doc.subset_fonts(); doc.save(SOURCE)

def translated(request):
    prompt = request['messages'][-1]['content']
    english = 'professional en native translator' in prompt
    def transform(text):
        chunks = re.split(r'(<[^>]+>|\{v\d+\})', text)
        return ''.join(chunk if chunk.startswith('<') or re.fullmatch(r'\{v\d+\}', chunk) else (' Study translation. ' if english else ' 研究译文。 ') if chunk.strip() else chunk for chunk in chunks)
    if '## Here is the input:' in prompt:
        rows = json.loads(prompt.split('## Here is the input:')[-1].strip())
        return json.dumps([{'id': row['id'], 'output': transform(row['input'])} for row in rows], ensure_ascii=False)
    return transform(prompt.split('Now translate the following text:')[-1].strip())

service = ControlledService(translated)
cases = [
    ('default', {}, 'englishToChinese', 'finished'),
    ('serif', {'primary_font_family': 'serif'}, 'englishToChinese', 'finished'),
    ('sans', {'primary_font_family': 'sans-serif'}, 'englishToChinese', 'finished'),
    ('script', {'primary_font_family': 'script'}, 'englishToChinese', 'finished'),
    ('formula-rules', {'formular_font_pattern': '.*Courier.*', 'formular_char_pattern': '[=+^]', 'add_formula_placehold_hint': True, 'skip_formula_offset_calculation': True}, 'englishToChinese', 'finished'),
    ('line-render-controls', {'split_short_lines': True, 'short_line_split_factor': 0.5, 'merge_alternating_line_numbers': False, 'remove_non_formula_lines': True, 'non_formula_line_iou_threshold': 0.5, 'figure_table_protection_threshold': 0.8, 'skip_form_render': True, 'skip_curve_render': True}, 'englishToChinese', 'finished'),
    ('enhanced-compatibility', {'enhance_compatibility': True, 'skip_clean': True, 'disable_rich_text_translate': True}, 'englishToChinese', 'finished'),
    ('chinese-to-english', {'primary_font_family': 'serif'}, 'chineseToEnglish', 'finished'),
    ('invalid-regex', {'formular_char_pattern': '('}, 'englishToChinese', 'invalidFormulaPattern'),
]
for name, options, direction, expected in cases:
    if os.environ.get('PDF_TEST_CASE') and name not in os.environ['PDF_TEST_CASE'].split(','): continue
    service.reset()
    payload = {'protocol': 1, 'inputFile': str(SOURCE), 'outputDirectory': str(RUN/name), 'workingDirectory': str(RUN/(name+'-working')), 'cacheDirectory': str(CACHE), 'controlledLoopback': True, 'maximumRequests': 40, 'direction': direction, 'provider': {'profileID': 'layout-probe', 'baseURL': service.endpoint, 'model': 'controlled'}, 'apiKey': 'CONTROLLED', 'options': {'auto_extract_glossary': False, 'no_mono': True, 'qps': 4, 'ignore_cache': True} | options}
    started = time.monotonic()
    result = subprocess.run([sys.executable, '-u', str(ROOT/'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py')], input=json.dumps(payload), capture_output=True, text=True, timeout=150)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    final = events[-1]; outcome = final.get('code', final['type'])
    (RUN/(name+'-events.jsonl')).write_text(result.stdout)
    (RUN/(name+'-requests.json')).write_text(json.dumps(service.requests, ensure_ascii=False, indent=2)+'\n')
    facts = {}
    for output in final.get('outputs', []):
        with pymupdf.open(output['path']) as doc:
            facts[output['kind']] = {'pages': len(doc), 'text': [p.get_text() for p in doc], 'fonts': sorted(set(font[3] for p in doc for font in p.get_fonts())), 'drawings': [len(p.get_drawings()) for p in doc], 'translatedSpans': [{'font': span['font'], 'flags': span['flags'], 'text': span['text']} for p in doc for block in p.get_text('dict')['blocks'] if 'lines' in block for line in block['lines'] for span in line['spans'] if '研究译文' in span['text'] or 'Study translation' in span['text']]}
            doc[0].get_pixmap().save(RUN/(name+'-'+output['kind']+'.png'))
    record = {'case': name, 'options': options, 'direction': direction, 'outcome': outcome, 'expected': expected, 'requests': len(service.requests), 'seconds': round(time.monotonic()-started,3), 'outputs': facts, 'realEngine': True, 'service': 'controlled localhost', 'costUSD': 0}
    (RUN/(name+'-result.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k:record[k] for k in ['case','outcome','expected','requests','seconds']}, ensure_ascii=False), flush=True)
    if os.environ.get('PDF_TEST_DISCOVER'): continue
    assert outcome == expected, (name, final)
    if outcome == 'finished':
        assert facts['dual']['pages'] == 1
        assert '研究译文' in facts['dual']['text'][0] or 'Study translation' in facts['dual']['text'][0]
        span_fonts = ' '.join(span['font'] for span in facts['dual']['translatedSpans'])
        if name == 'serif': assert 'SourceHanSerif' in span_fonts.replace(' ', ''), span_fonts
        if name == 'sans': assert 'SourceHanSans' in span_fonts.replace(' ', ''), span_fonts
        if name == 'script': assert 'LXGW' in span_fonts, span_fonts
        assert not re.search(r'\{v\d+\}', facts['dual']['text'][0]), 'Unresolved formula placeholder'
        if name == 'formula-rules': assert facts['dual']['text'][0].count('E = mc^2 + a/b') >= 4, facts['dual']['text'][0]
    else: assert not service.requests
service.close()
