#!/usr/bin/env python3
"""T23 authored fixtures and actual long-document engine run; loopback only."""
import argparse, hashlib, json, shutil, subprocess, sys, time, unicodedata
from pathlib import Path
import pymupdf
from engine_test_support import ControlledService

parser=argparse.ArgumentParser()
parser.add_argument('--assets',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[2]
font=args.assets/'fonts/SourceHanSerifCN-Regular.ttf'
chinese=args.output/'chinese-source.pdf'
with pymupdf.open() as doc:
    p=doc.new_page(width=595,height=842)
    p.insert_font(fontname='Chinese',fontfile=str(font))
    p.insert_text((55,80),'量子实验记录',fontname='Chinese',fontsize=18)
    for i,line in enumerate(['一个量子比特可以在受控条件下保持相干。','研究者测量量子态，并记录每一步观察。','原始资料和翻译结果分别保存。']):
        p.insert_text((55,120+i*28),line,fontname='Chinese',fontsize=15)
    doc.subset_fonts();doc.save(chinese)
with pymupdf.open(chinese) as doc:
    chinese_text=doc[0].get_text();normalized=unicodedata.normalize('NFKC',chinese_text);assert '量子' in normalized and '原始' in normalized
    doc[0].get_pixmap().save(args.output/'chinese-source.png')
source=args.output/'long-original.pdf'
with pymupdf.open() as doc:
    for index in range(24):
        page=doc.new_page(width=595,height=842)
        page.insert_text((48,60),f'Long-document evidence PAGE-{index+1:02d}',fontsize=17)
        for paragraph in range(5):
            text=f'Observation {paragraph+1} on page {index+1}. The research team preserves the original document and records the translated result independently. A repeated measurement helps identify a change in the experimental conditions.'
            page.insert_textbox((48,90+paragraph*125,547,195+paragraph*125),text,fontsize=12)
    doc.save(source)
original_hash=hashlib.sha256(source.read_bytes()).hexdigest()
def response(request):
    prompt=request['messages'][-1]['content']
    if '## Here is the input:' in prompt:
        rows=json.loads(prompt.split('## Here is the input:')[-1].strip())
        return json.dumps([{'id':r['id'],'output':'研究记录译文。原始资料独立保留，重复测量用于核对实验条件。'} for r in rows],ensure_ascii=False)
    return '研究记录译文。原始资料独立保留，重复测量用于核对实验条件。'
service=ControlledService(response)
payload={'protocol':1,'inputFile':str(source),'outputDirectory':str(args.output/'generated'),'workingDirectory':str(args.output/'working'),'cacheDirectory':str(args.assets),'direction':'englishToChinese','controlledLoopback':True,'maximumRequests':180,'provider':{'profileID':'t23-controlled-long','baseURL':service.endpoint,'model':'controlled'},'apiKey':'T23_CONTROLLED_NEVER_LOG','options':{'auto_extract_glossary':False,'no_mono':False,'no_dual':False,'max_pages_per_part':6,'ignore_cache':True,'qps':10,'pool_max_workers':3,'watermark_output_mode':'no_watermark'}}
try:
    started=time.monotonic()
    process=subprocess.run([sys.executable,'-u',str(root/'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py')],input=json.dumps(payload)+'\n',capture_output=True,text=True,timeout=300)
    (args.output/'events.jsonl').write_text(process.stdout);(args.output/'stderr.txt').write_text(process.stderr)
    (args.output/'requests.json').write_text(json.dumps(service.requests,ensure_ascii=False,indent=2))
    final=json.loads(process.stdout.splitlines()[-1]);assert process.returncode==0 and final['type']=='finished',final
    facts={}
    for item in final['outputs']:
        file=Path(item['path']);target=args.output/(item['kind']+'.pdf');shutil.copy2(file,target)
        with pymupdf.open(file) as doc:
            texts=[p.get_text() for p in doc];assert len(doc)==24
            if item['kind']=='dual':
                for i,t in enumerate(texts): assert f'PAGE-{i+1:02d}' in t,(i,t)
            assert all('研究' in t for t in texts)
            facts[item['kind']]={'pages':len(doc),'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'text':texts}
            for index in [0,5,6,23]:doc[index].get_pixmap().save(args.output/(item['kind']+f'-page-{index+1:02d}.png'))
    assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash
    summary={'engine':'0.6.4','integration':1,'realEngine':True,'service':'controlled localhost','costUSD':0,'pages':24,'pagesPerPart':6,'seconds':round(time.monotonic()-started,3),'requests':len(service.requests),'diagnostics':final['diagnostics'],'sourceSHA256':original_hash,'outputs':facts,'chineseFixture':{'file':chinese.name,'sha256':hashlib.sha256(chinese.read_bytes()).hexdigest(),'text':chinese_text,'realProviderRun':False}}
    (args.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:summary[k] for k in ['pages','pagesPerPart','seconds','requests','costUSD']}),flush=True)
finally:service.close()
