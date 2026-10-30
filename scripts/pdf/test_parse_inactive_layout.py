#!/usr/bin/env python3
"""Review regression: real parse-only pipeline ignores inactive invalid layout."""
import argparse, hashlib, json, shutil, subprocess, sys
from pathlib import Path
import pymupdf
parser=argparse.ArgumentParser(); parser.add_argument('--assets', type=Path, required=True); parser.add_argument('--output', type=Path, required=True); args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=False)
source=args.output/'original.pdf'
with pymupdf.open() as doc:
    page=doc.new_page();page.insert_text((50,80),'Local parsing keeps the source text without translation.');doc.save(source)
original_hash=hashlib.sha256(source.read_bytes()).hexdigest()
root=Path(__file__).resolve().parents[2]
payload={'protocol':1,'inputFile':str(source),'outputDirectory':str(args.output/'output'),'workingDirectory':str(args.output/'working'),'cacheDirectory':str(args.assets),'direction':'englishToChinese','apiKey':'',
 'options':{'only_parse_generate_pdf':True,'auto_extract_glossary':False,'watermark_output_mode':'no_watermark','formular_font_pattern':'(','formular_char_pattern':'x'*4097,'short_line_split_factor':-1,'non_formula_line_iou_threshold':5,'enhance_compatibility':True,'skip_form_render':True}}
run=subprocess.run([sys.executable,'-u',str(root/'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py')],input=json.dumps(payload)+'\n',text=True,capture_output=True,timeout=90)
(args.output/'events.jsonl').write_text(run.stdout);(args.output/'stderr.txt').write_text(run.stderr)
last=json.loads(run.stdout.splitlines()[-1]); assert run.returncode==0 and last['type']=='finished',last
assert last['requestCount']==0
for output in last['outputs']:
    shutil.copy2(output['path'], args.output/(output['kind']+'.pdf'))
    with pymupdf.open(output['path']) as doc:
        assert doc.page_count==1 and 'Local parsing' in doc[0].get_text();doc[0].get_pixmap().save(args.output/(output['kind']+'.png'))
assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash
(args.output/'summary.json').write_text(json.dumps({'engine':'0.6.4','mode':'parse-only','invalidInactivePatternsIgnored':True,'invalidInactiveNumericSettingsIgnored':True,'requestCount':0,'providerConfigured':False,'readablePDF':True,'originalHash':original_hash,'costUSD':0},indent=2))
print('PASS real parse-only, invalid inactive layout, no provider/key, zero HTTP requests')
