#!/usr/bin/env python3
"""T22 real BabelDOC rate, pool, extraction, cache and safe metadata evidence."""
import argparse, hashlib, json, re, shutil, subprocess, sys, time
from pathlib import Path
import pymupdf
from engine_test_support import ControlledService
parser=argparse.ArgumentParser();parser.add_argument('--assets',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--extended-only',action='store_true');parser.add_argument('--same-target-cache-only',action='store_true');parser.add_argument('--term-failure-only',action='store_true');parser.add_argument('--inactive-term-workers-only',action='store_true');args=parser.parse_args()
args.output.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[2]; bridge=root/'app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py'
source=args.output/'original.pdf'; single=args.output/'single.pdf'
for path,count in [(source,4),(single,1)]:
    with pymupdf.open() as doc:
        for index in range(count):
            page=doc.new_page();page.insert_text((60,90),f'Page {index+1}: Latency and cache help an independent translation workflow.',fontsize=12)
            page.insert_text((60,115),f'This is example {index+1} for preserving PDF material and useful engineering terms.',fontsize=12)
        doc.save(path)
original_hash=hashlib.sha256(source.read_bytes()).hexdigest()
def response(request):
    prompt=request['messages'][-1]['content']
    if request['model']=='terms' or 'You are an expert multilingual terminologist.' in prompt: return json.dumps([{'src':'Latency','tgt':'延迟'},{'src':'cache','tgt':'缓存'}],ensure_ascii=False)
    if '## Here is the input:' in prompt:
        rows=json.loads(prompt.split('## Here is the input:')[-1].strip())
        return json.dumps([{'id':row['id'],'output':'延迟与缓存用于独立翻译工作流程。保留资料与工程术语。'} for row in rows],ensure_ascii=False)
    return '延迟与缓存用于独立翻译工作流程。保留资料与工程术语。'
service=ControlledService(response,delay=0.65)
summary=[]
def run(name, options=None, extraction=False, file=source, provider='t22-primary', maximum=50, expected='finished', cancel=False, separate_terms=True):
    service.reset(); folder=args.output/name;folder.mkdir()
    settings={'no_mono':True,'qps':20,'pool_max_workers':4,'term_pool_max_workers':1,'auto_extract_glossary':extraction,'save_auto_extracted_glossary':extraction,'ignore_cache':True,'report_interval':0.1,'skip_scanned_detection':True}
    settings.update(options or {})
    payload={'protocol':1,'inputFile':str(file),'outputDirectory':str(folder/'output'),'workingDirectory':str(folder/'working'),'cacheDirectory':str(args.assets),'direction':'englishToChinese','controlledLoopback':True,'maximumRequests':maximum,'provider':{'profileID':provider,'baseURL':service.endpoint,'model':'primary'},'apiKey':'T22_CONTROLLED_KEY_NEVER_LOG','options':settings}
    if settings.get('skip_translation') or settings.get('only_parse_generate_pdf'): payload.pop('provider');payload['apiKey']=''
    elif extraction and separate_terms: payload['termExtraction']={'provider':{'profileID':'t22-terms','baseURL':service.endpoint,'model':'terms'},'apiKey':'T22_TERM_KEY_NEVER_LOG','reasoning':'low'}
    start=time.monotonic()
    if cancel:
        process=subprocess.Popen([sys.executable,'-u',str(bridge)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        process.stdin.write(json.dumps(payload)+'\n');process.stdin.close();process.stdin=None
        deadline=time.monotonic()+60
        while not service.requests and process.poll() is None and time.monotonic()<deadline: time.sleep(.05)
        assert service.requests,'No request before cancel'
        killed=False;process.terminate()
        try: stdout,stderr=process.communicate(timeout=2)
        except subprocess.TimeoutExpired: process.kill();killed=True;stdout,stderr=process.communicate(timeout=5)
        assert process.poll() is not None
        # Server handler may still finish its controlled delay after client dies.
        deadline=time.monotonic()+10
        while service.active and time.monotonic()<deadline: time.sleep(.05)
    else:
        process=subprocess.run([sys.executable,'-u',str(bridge)],input=json.dumps(payload)+'\n',text=True,capture_output=True,timeout=150);stdout,stderr=process.stdout,process.stderr
    events=[json.loads(line) for line in stdout.splitlines()]
    (folder/'events.jsonl').write_text(stdout);(folder/'stderr.txt').write_text(stderr)
    (folder/'requests.json').write_text(json.dumps(service.requests,ensure_ascii=False,indent=2))
    assert all(token not in stdout+stderr for token in ['T22_CONTROLLED_KEY','T22_TERM_KEY','CONTROLLED_PRIVATE_ERROR'])
    record={'case':name,'seconds':round(time.monotonic()-start,3),'requests':len(service.requests),'maximumActiveHTTP':service.maximum_active,'returnCode':process.returncode,'controlledService':True,'costUSD':0}
    times=sorted(row['time'] for row in service.requests); record['minimumRequestGap']=round(min((b-a for a,b in zip(times,times[1:])),default=0),4)
    if cancel:
        record.update(terminated=True,requiredKill=killed);assert not any(e['type']=='finished' for e in events)
    elif expected=='finished':
        assert process.returncode==0 and events[-1]['type']=='finished',events[-1:]
        final=events[-1];diagnostics=final['diagnostics'];record['diagnostics']=diagnostics
        assert diagnostics['requestCount']==len(service.requests)
        assert diagnostics['translationRequests']==sum('You are an expert multilingual terminologist.' not in row['request']['messages'][-1]['content'] for row in service.requests)
        assert diagnostics['termRequests']==sum('You are an expert multilingual terminologist.' in row['request']['messages'][-1]['content'] for row in service.requests)
        if service.usage and service.requests:
            assert diagnostics['responsesWithUsage']==len(service.requests)
            assert diagnostics['promptTokens']==len(service.requests)*100 and diagnostics['completionTokens']==len(service.requests)*20
        else: assert diagnostics['responsesWithUsage']==0 and 'promptTokens' not in diagnostics and 'completionTokens' not in diagnostics
        pdf=next(Path(out['path']) for out in final['outputs'] if out['kind']=='dual')
        shutil.copy2(pdf,folder/'dual.pdf')
        with pymupdf.open(pdf) as doc:
            assert doc.page_count>0;doc[0].get_pixmap().save(folder/'dual.png')
            record['drawings']=len(doc[0].get_drawings());record['pages']=doc.page_count
        record['progressEvents']=sum(e['type']=='progress' for e in events)
    else:
        assert process.returncode!=0 and events[-1]=={'type':'failed','code':expected},events[-1:]
        record['failure']=expected
    summary.append(record);(args.output/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(record),flush=True)
    return record,list(service.requests)
try:
    if args.inactive_term_workers_only:
        result,_=run('inactive-term-workers',{'term_pool_max_workers':0},extraction=False,file=single)
        assert result['requests']>0 and result['diagnostics']['termRequests']==0
    elif args.term_failure_only:
        service.status=429
        failed,rows=run('term-failure-stops-translation',extraction=True,file=single,expected='rateLimited')
        assert failed['requests']==1 and all(row['request']['model']=='terms' for row in rows), 'Primary translation must not start after extraction failed'
    elif args.same_target_cache_only:
        first,_=run('same-target-cache-populate',{'ignore_cache':False},extraction=True,file=single,separate_terms=False)
        cached,_=run('same-target-cache-reuse',{'ignore_cache':False},extraction=True,file=single,separate_terms=False)
        assert first['diagnostics']['translationRequests'] > 0 and first['diagnostics']['termRequests'] > 0
        assert cached['requests']==0 and cached['diagnostics']['translationCacheHits']>0 and cached['diagnostics']['termCacheHits']>0
    elif args.extended_only:
        baseline,_=run('progress-default',{'qps':2})
        sparse,_=run('progress-sparse',{'qps':2,'report_interval':60})
        assert sparse['progressEvents'] < baseline['progressEvents']
        def same_text(request):
            prompt=request['messages'][-1]['content']
            if '## Here is the input:' in prompt:
                rows=json.loads(prompt.split('## Here is the input:')[-1].strip())
                return json.dumps([{'id':row['id'],'output':row['input']} for row in rows])
            if 'Now translate the following text:' in prompt: return prompt.split('Now translate the following text:')[-1].strip()
            if 'Input:\n\n' in prompt: return prompt.split('Input:\n\n')[-1].strip()
            return 'Unchanged controlled fallback.'
        service.response=same_text
        fallback,_=run('same-text-fallback-on',file=single)
        disabled,_=run('same-text-fallback-off',{'disable_same_text_fallback':True},file=single)
        assert fallback['requests'] > disabled['requests']
    else:
        slow,_=run('qps-two',{'qps':2});assert slow['minimumRequestGap']>=.45
        serial,_=run('one-worker',{'pool_max_workers':1});assert serial['maximumActiveHTTP']==1
        parallel,_=run('four-workers');assert 1<parallel['maximumActiveHTTP']<=4
        terms1,_=run('term-worker-one',extraction=True);assert terms1['diagnostics']['termRequests']>=2
        terms3,termrequests=run('term-workers-three',{'term_pool_max_workers':3},extraction=True)
        def role_overlap(rows,role):
            times=[r['time'] for r in rows if r['request']['model']==role]
            return max((sum(0<=later-earlier<service.delay-.05 for later in times) for earlier in times),default=0)
        # Actual extraction stage completes before translation; infer overlapping
        # responses from known controlled delay as well as the overall HTTP peak.
        rows=json.loads((args.output/'term-worker-one/requests.json').read_text())
        assert role_overlap(rows,'terms')==1 and role_overlap(termrequests,'terms')>1
        first,_=run('cache-populate',{'ignore_cache':False},file=single)
        cached,_=run('cache-reuse',{'ignore_cache':False},file=single);assert first['requests']>0 and cached['requests']==0 and cached['diagnostics']['translationCacheHits']>0
        bypass,_=run('cache-bypass',{'ignore_cache':True},file=single);assert bypass['requests']>0
        changed,_=run('cache-target-isolation',{'ignore_cache':False},file=single,provider='t22-other-target');assert changed['requests']>0
        compat,rows=run('request-compatibility',{'enable_json_mode_if_requested':True,'send_dashscope_header':True,'send_temperature':False,'openai_reasoning':'medium','openai_thinking':'disabled'},extraction=True,file=single)
        assert all('temperature' not in r['request'] and r['request']['thinking']=={'type':'disabled'} for r in rows)
        assert any(r['request'].get('response_format')=={'type':'json_object'} for r in rows)
        assert all(r['request']['reasoning']=={'effort':'low' if r['request']['model']=='terms' else 'medium'} for r in rows)
        assert all(r['dashScopeHeader'] for r in rows)
        service.usage=False;run('missing-usage',file=single);service.usage=True
        plain,_=run('local-typeset',{'skip_translation':True},file=single)
        diagnostic,_=run('diagnostic-character-boxes',{'skip_translation':True,'debug':True,'show_char_box':True},file=single)
        assert diagnostic['requests']==0 and diagnostic['drawings']>plain['drawings']
        service.status=429;limited,_=run('rate-limit',expected='rateLimited');assert 1<=limited['requests']<=4;service.status=200
        bounded,_=run('shared-request-budget',extraction=True,maximum=2,expected='requestLimit');assert bounded['requests']==2
        service.delay=3;run('cancel-internal-workers',cancel=True)
        assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash
finally: service.close()
print('PASS real T22 performance matrix; original unchanged; all services controlled; cost $0')
