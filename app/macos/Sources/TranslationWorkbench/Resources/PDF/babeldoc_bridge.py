#!/usr/bin/env python3
"""Protocol v1. One isolated process per PDF job; secrets arrive only on stdin."""
import contextlib
import importlib.metadata
import json
import logging
import math
import os
from pathlib import Path
import re
import signal
import sys
import threading
import time
from urllib.parse import urlsplit
from uuid import UUID

PROTOCOL = 1
ENGINE = '0.6.4'
# Exact installed release's supported-language table:
# https://github.com/funstory-ai/BabelDOC/blob/v0.6.4/docs/supported_languages.md
SUPPORTED_LANGUAGE_CODES = frozenset('''en zh zh-hk zh-tw ja ko pl ru es pt fr ms id tk tl vi kk de nl ga it el sv da no is fi uk cs ro hu sk hr et lv lt be mk sq sr sl ca bg mt sw am om ti ht la lo ml gu th my ta te or hy mn ka km bs lb rm tr si uz ky tg ab aa af ak an av ee ay oj oc os pi ba eu br ch ce cv tn nr ng fo fj fy lg kg kl cu gn ia hz ki rn rw gl kr kw kv xh co cr qu ku kj li ln gv mg mh mi nv na ny nn sc se sm sg sn eo gd so st tt ty to tw wa cy ve vo ie ho ig io iu ik ii yo za ts zu pt-br'''.split())
OUTPUT = sys.stdout
cancelled = threading.Event()

def emit(**value):
    OUTPUT.write(json.dumps(value, ensure_ascii=False, separators=(',', ':'))+'\n')
    OUTPUT.flush()

class BridgeFailure(Exception):
    def __init__(self, code): self.code = code

def language_code(value):
    if not isinstance(value, str): raise BridgeFailure('configuration')
    value = value.strip().lower().replace('_', '-')
    return {'zh-hans': 'zh', 'zh-cn': 'zh', 'zh-hant': 'zh-tw',
            'fil': 'tl', 'pt-pt': 'pt', 'nb': 'no'}.get(value, value)

def translation_languages(request):
    if 'sourceLanguage' in request or 'targetLanguage' in request:
        source, target = language_code(request.get('sourceLanguage')), language_code(request.get('targetLanguage'))
    else:
        direction = request.get('direction', 'englishToChinese')
        if direction == 'englishToChinese': source, target = 'en', 'zh'
        elif direction == 'chineseToEnglish': source, target = 'zh', 'en'
        else: raise BridgeFailure('configuration')
    if source not in SUPPORTED_LANGUAGE_CODES or target not in SUPPORTED_LANGUAGE_CODES: raise BridgeFailure('configuration')
    return source, target

def run(request):
    started = time.monotonic()
    if request.get('protocol') != PROTOCOL:
        raise BridgeFailure('configuration')
    if importlib.metadata.version('babeldoc') != ENGINE:
        raise BridgeFailure('runtimeIncompatible')
    cache = Path(request['cacheDirectory']).resolve()
    cache.mkdir(parents=True, exist_ok=True)
    import babeldoc.const as const
    const.CACHE_FOLDER = cache
    const.TIKTOKEN_CACHE_FOLDER = cache/'tiktoken'
    const.TIKTOKEN_CACHE_FOLDER.mkdir(exist_ok=True)
    os.environ['TIKTOKEN_CACHE_DIR'] = str(const.TIKTOKEN_CACHE_FOLDER)
    import babeldoc_compat
    babeldoc_compat.install()
    from babeldoc.translator.translator import BaseTranslator, OpenAITranslator, RateLimiter, set_translate_rate_limiter
    from babeldoc.format.pdf.translation_config import TranslationConfig, WatermarkOutputMode
    from babeldoc.format.pdf.high_level import do_translate, get_translation_stage
    from babeldoc.progress_monitor import ProgressMonitor
    from babeldoc.docvision.doclayout import DocLayoutModel
    import httpx
    import openai
    import pymupdf

    options = dict(request.get('options', {}))
    if not options.get('auto_extract_glossary', True) or options.get('skip_translation') or options.get('only_parse_generate_pdf'):
        options.pop('term_pool_max_workers', None)
    for name in ('qps', 'pool_max_workers', 'term_pool_max_workers'):
        value = options.get(name, 4 if name == 'qps' else None)
        if value is not None and (type(value) is not int or not 1 <= value <= 100): raise BridgeFailure('configuration')
    interval = options.get('report_interval', 0.1)
    if type(interval) not in (float, int) or not math.isfinite(interval) or not 0.05 <= interval <= 60: raise BridgeFailure('configuration')
    for name in ('ignore_cache', 'enable_json_mode_if_requested', 'send_dashscope_header', 'send_temperature', 'debug', 'show_char_box', 'disable_same_text_fallback'):
        if name in options and type(options[name]) is not bool: raise BridgeFailure('configuration')
    if options.get('openai_thinking') not in (None, 'enabled', 'disabled'): raise BridgeFailure('configuration')
    reasoning = options.get('openai_reasoning')
    if reasoning is not None and (not isinstance(reasoning, str) or len(reasoning.encode()) > 200 or any(ord(c) < 32 or ord(c) == 127 for c in reasoning)): raise BridgeFailure('configuration')
    for name in ('skip_translation', 'only_parse_generate_pdf'):
        if type(options.get(name, False)) is not bool: raise BridgeFailure('configuration')
    requires_service = not (options.get('skip_translation', False) or options.get('only_parse_generate_pdf', False))
    source,target = translation_languages(request)
    maximum_requests = request.get('maximumRequests',10000)
    if not isinstance(maximum_requests,int) or not 1 <= maximum_requests <= 10000:
        raise BridgeFailure('configuration')
    # A shared request budget covers the explicitly selected translation and
    # optional terminology targets. Neither target inherits the other's key.
    request_count = 0
    run_failure = None
    role_requests = {'translation': 0, 'term': 0}
    usage = {'responses': 0, 'prompt': 0, 'completion': 0}
    request_lock = threading.Lock()
    # Upstream throttles before constructing SDK requests. Recheck at transport
    # dispatch so first-use SDK work cannot bunch actual outbound requests.
    outbound_limiter = RateLimiter(options.get('qps',4))
    translators = []
    class LocalOnlyTranslator(BaseTranslator):
        name = 'workbench-local'
        model = ENGINE
        failure = None
        def do_llm_translate(self, text, rate_limit_params=None):
            if text is None: return None  # Upstream's capability probe.
            self.failure = 'configuration'
            raise BridgeFailure('configuration')
        def do_translate(self, text, rate_limit_params=None):
            self.failure = 'configuration'
            raise BridgeFailure('configuration')
    class BoundedTransport(httpx.BaseTransport):
        def __init__(self, endpoint, role):
            self.role = role
            self.origin = urlsplit(endpoint)
            self.transport=httpx.HTTPTransport(retries=0,trust_env=False)
        def handle_request(self, req):
            nonlocal request_count
            outbound_limiter.wait()
            with request_lock:
                if cancelled.is_set(): raise BridgeFailure('cancelled')
                if run_failure: raise BridgeFailure(run_failure)
                if request_count >= maximum_requests: raise BridgeFailure('requestLimit')
                request_count += 1
                role_requests[self.role] += 1
            url = self.origin
            if (req.url.scheme,req.url.host,req.url.port or (443 if req.url.scheme=='https' else 80))!=(url.scheme,url.hostname,url.port or (443 if url.scheme=='https' else 80)):
                raise BridgeFailure('configuration')
            return self.transport.handle_request(req)
        def close(self): self.transport.close()
    class Translator(OpenAITranslator):
        failure=None
        def update_token_count(self, response):
            super().update_token_count(response)
            reported = getattr(response, 'usage', None)
            prompt = getattr(reported, 'prompt_tokens', None)
            completion = getattr(reported, 'completion_tokens', None)
            if type(prompt) is int and prompt >= 0 and type(completion) is int and completion >= 0:
                with request_lock:
                    usage['responses'] += 1; usage['prompt'] += prompt; usage['completion'] += completion
        def guarded(self, method, *args, **kwargs):
            nonlocal run_failure
            with request_lock:
                failure = run_failure or self.failure
            if failure: raise BridgeFailure(failure)
            try: return method(self,*args,**kwargs)
            except BaseException as error:
                if isinstance(error,(KeyboardInterrupt,SystemExit)): raise
                self.failure=error_code(error)
                with request_lock:
                    # Upstream may catch a terminology error and continue to
                    # translation. A failed stage must not spend on later work.
                    if run_failure is None: run_failure = self.failure
                raise
        def simple(self,text,rate_limit_params=None):
            response = self.client.chat.completions.create(model=self.model,
                **(self.options if self.send_temperature else {}), max_tokens=2048,
                messages=self.prompt(text), extra_body=self.extra_body)
            self.update_token_count(response)
            return response.choices[0].message.content.strip()
        def do_translate(self,*args,**kwargs):
            return self.guarded(Translator.simple,*args,**kwargs)
        def do_llm_translate(self,*args,**kwargs):
            return self.guarded(OpenAITranslator.do_llm_translate.__wrapped__,*args,**kwargs)
    def make_translator(provider, key, role, reasoning=None):
        endpoint = provider['baseURL']
        url = urlsplit(endpoint)
        loopback = request.get('controlledLoopback',False) and url.hostname in ('127.0.0.1','localhost')
        if (url.scheme != 'https' and not loopback) or url.username or url.password or url.query or url.fragment or not key:
            raise BridgeFailure('configuration')
        translator = Translator(source,target,provider['model'],base_url=endpoint,api_key=key,
            ignore_cache=options.get('ignore_cache',False),reasoning=reasoning,
            enable_json_mode_if_requested=options.get('enable_json_mode_if_requested',False),
            send_dashscope_header=options.get('send_dashscope_header',False),send_temperature=options.get('send_temperature',True),
            thinking=options.get('openai_thinking'))
        translator.workbench_role = role
        translator.client.close()
        translator.client = openai.OpenAI(api_key=key,base_url=endpoint,max_retries=0,
            http_client=httpx.Client(transport=BoundedTransport(endpoint,role),timeout=60,follow_redirects=False,trust_env=False))
        translator.add_cache_impact_parameters('workbench_provider',provider['profileID']+'|'+endpoint)
        translators.append(translator)
        return translator
    if requires_service:
        translator = make_translator(request['provider'],request['apiKey'],'translation',options.get('openai_reasoning'))
    else:
        if request.get('provider') or request.get('termExtraction') or request.get('apiKey'):
            raise BridgeFailure('configuration')
        translator = LocalOnlyTranslator(source,target,True)
        translators.append(translator)
    term_translator = translator
    if request.get('termExtraction'):
        term = request['termExtraction']
        # Separate target must explicitly carry its matching credential.
        term_translator = make_translator(term['provider'],term['apiKey'],'term',term.get('reasoning'))
    elif requires_service and options.get('auto_extract_glossary',True):
        # Same explicit target and its own matching key; distinct instances let
        # diagnostics distinguish extraction from translation without text logs.
        term_translator = make_translator(request['provider'],request['apiKey'],'term',options.get('openai_reasoning'))
    from babeldoc.glossary import Glossary, GlossaryEntry
    glossaries=[]
    for glossary in request.get('resources',{}).get('glossaries',[]):
        entries=[]
        for entry in glossary['entries']:
            language = entry.get('targetLanguage')
            if language and language_code(language) != target: continue
            entries.append(GlossaryEntry(entry['source'],entry['target'],language))
        # The pinned engine indexes active glossary tables by name. User-visible
        # names need not be unique; a stable ID prevents one table hiding another.
        engine_name = glossary['name'] + ' [id:' + str(UUID(glossary['id'])) + ']'
        if entries: glossaries.append(Glossary(engine_name,entries))
    allowed={'no_dual','no_mono','pages','min_text_length','formular_font_pattern','formular_char_pattern','qps',
        'split_short_lines','short_line_split_factor','skip_clean','dual_translate_first','disable_rich_text_translate',
        'enhance_compatibility','report_interval','use_alternating_pages_dual','skip_scanned_detection','ocr_workaround',
        'custom_system_prompt','add_formula_placehold_hint','pool_max_workers','auto_extract_glossary','auto_enable_ocr_workaround',
        'primary_font_family','only_include_translated_page','save_auto_extracted_glossary','enable_graphic_element_process',
        'merge_alternating_line_numbers','skip_translation','skip_form_render','skip_curve_render','only_parse_generate_pdf',
        'remove_non_formula_lines','non_formula_line_iou_threshold','figure_table_protection_threshold','skip_formula_offset_calculation',
        'term_pool_max_workers','disable_same_text_fallback','debug','show_char_box'}
    special={'ignore_cache','watermark_output_mode','max_pages_per_part','enable_json_mode_if_requested','send_dashscope_header','send_temperature','openai_reasoning','openai_thinking'}
    if set(options)-allowed-special: raise BridgeFailure('configuration')
    if options.get('only_parse_generate_pdf') and options.get('watermark_output_mode', 'watermarked') != 'no_watermark': raise BridgeFailure('configuration')
    settings={key:value for key,value in options.items() if key in allowed}
    if settings.get('only_parse_generate_pdf'):
        # Parse-only bypasses these stages. Preserve UI snapshots but do not let
        # inactive patterns or numeric values reject local parse-and-generate.
        inactive = {'formular_font_pattern','formular_char_pattern','primary_font_family','split_short_lines',
            'short_line_split_factor','skip_clean','disable_rich_text_translate','enhance_compatibility',
            'add_formula_placehold_hint','merge_alternating_line_numbers','remove_non_formula_lines',
            'non_formula_line_iou_threshold','figure_table_protection_threshold','skip_formula_offset_calculation'}
        settings = {key:value for key,value in settings.items() if key not in inactive}
    for pattern_name in ('formular_font_pattern', 'formular_char_pattern'):
        if pattern_name in settings:
            pattern = settings[pattern_name]
            if not isinstance(pattern, str) or len(pattern.encode()) > 4096: raise BridgeFailure('configuration')
            try: re.compile(pattern)
            except re.error: raise BridgeFailure('invalidFormulaPattern')
    for name in ('short_line_split_factor', 'non_formula_line_iou_threshold', 'figure_table_protection_threshold'):
        if name in settings:
            value = settings[name]
            if type(value) not in (int, float) or not math.isfinite(value): raise BridgeFailure('configuration')
            if name == 'short_line_split_factor':
                if value <= 0: raise BridgeFailure('configuration')
            elif not 0 <= value <= 1: raise BridgeFailure('configuration')
    if settings.get('primary_font_family') not in (None, 'serif', 'sans-serif', 'script'): raise BridgeFailure('configuration')
    settings.setdefault('no_mono',True)
    settings.setdefault('qps',4)
    settings.setdefault('save_auto_extracted_glossary',False)
    if not requires_service:
        settings['auto_extract_glossary'] = False
        settings['save_auto_extracted_glossary'] = False
    if type(settings.get('min_text_length', 5)) is not int or settings.get('min_text_length', 5) < 0:
        raise BridgeFailure('configuration')
    if settings.get('no_mono') and settings.get('no_dual'): raise BridgeFailure('configuration')
    # Recheck direct protocol callers before model loading or service requests.
    with pymupdf.open(request['inputFile']) as source_document:
        page_count = source_document.page_count
        if source_document.is_encrypted or page_count < 1: raise BridgeFailure('invalidPDF')
        extractable = [bool(page.get_text().strip()) for page in source_document]
    pages = settings.get('pages', '').strip()
    if len(pages) > 4096: raise BridgeFailure('configuration')
    if settings.get('only_include_translated_page') and not pages: raise BridgeFailure('configuration')
    if pages:
        selected_pages = set()
        for token in pages.split(','):
            match = re.fullmatch(r'([0-9]*)(?:-([0-9]*))?', token.strip())
            if not match or not any(match.groups()): raise BridgeFailure('configuration')
            start = int(match[1]) if match[1] else 1
            end = (int(match[2]) if match[2] else page_count) if match[2] is not None else start
            if not 1 <= start <= end <= page_count: raise BridgeFailure('configuration')
            selected_pages.update(range(start - 1, end))
        settings['pages'] = pages
    else: selected_pages = set(range(page_count))
    content_report = {'sourcePageCount':page_count,'selectedPageCount':len(selected_pages),
        'pagesWithoutExtractableText':sum(not extractable[index] for index in selected_pages)}
    part_size = options.get('max_pages_per_part')
    if part_size is not None and (type(part_size) is not int or part_size < 1): raise BridgeFailure('configuration')
    if not isinstance(settings['qps'],int) or not 1 <= settings['qps'] <= 100: raise BridgeFailure('configuration')
    set_translate_rate_limiter(settings['qps'])
    settings['watermark_output_mode']=WatermarkOutputMode(options.get('watermark_output_mode','watermarked'))
    if options.get('max_pages_per_part'):
        settings['split_strategy']=TranslationConfig.create_max_pages_per_part_split_strategy(options['max_pages_per_part'])
    emit(type='progress',stage='Preparing engine',progress=0)
    layout=DocLayoutModel.load_onnx()
    config=TranslationConfig(translator=translator,input_file=request['inputFile'],lang_in=source,lang_out=target,
        output_dir=request['outputDirectory'],working_dir=request['workingDirectory'],doc_layout_model=layout,
        use_rich_pbar=False,glossaries=glossaries,term_extraction_translator=term_translator,**settings)
    babeldoc_compat.preserve_first_output_watermark(config)
    def progress(**event):
        if event.get('type','').startswith('progress_'):
            emit(type='progress',stage=event.get('stage',''),progress=event.get('overall_progress',0))
    # Upstream async callback can wait forever after finish and on_finish emits
    # CancelledError even after success. Only the synchronous return is final.
    with ProgressMonitor(get_translation_stage(config),progress_change_callback=progress,
            finish_callback=lambda **event: None,cancel_event=cancelled,report_interval=config.report_interval) as monitor:
        try:
            result=do_translate(monitor,config)
        except Exception as error:
            if requires_service and content_report['pagesWithoutExtractableText'] == len(selected_pages) and type(error).__name__ == 'ExtractTextError':
                raise BridgeFailure('noExtractableText') from error
            raise
    for selected_translator in translators:
        if selected_translator.failure: raise BridgeFailure(selected_translator.failure)
    if requires_service and content_report['pagesWithoutExtractableText'] == len(selected_pages):
        raise BridgeFailure('noExtractableText')
    outputs=[]
    for kind,key in [('mono','mono_pdf_path'),('dual','dual_pdf_path'),('monoNoWatermark','no_watermark_mono_pdf_path'),('dualNoWatermark','no_watermark_dual_pdf_path')]:
        path=getattr(result,key,None)
        if not path or any(x['path']==str(path) for x in outputs): continue
        with pymupdf.open(path) as document:
            if document.page_count==0: raise BridgeFailure('invalidOutput')
        outputs.append({'kind':kind,'path':str(path)})
    expected = set()
    if not settings.get('no_mono'): expected.add('mono')
    if not settings.get('no_dual'): expected.add('dual')
    if options.get('watermark_output_mode') == 'both':
        expected |= {kind + 'NoWatermark' for kind in expected}
    if {output['kind'] for output in outputs} != expected: raise BridgeFailure('invalidOutput')
    glossary_path=getattr(result,'auto_extracted_glossary_path',None)
    if glossary_path and Path(glossary_path).is_file():
        outputs.append({'kind':'glossaryCSV','path':str(glossary_path)})
    diagnostics = {'requestCount':request_count,'translationRequests':role_requests['translation'],'termRequests':role_requests['term'],
        'translationCacheHits':sum(t.translate_cache_call_count for t in translators if getattr(t,'workbench_role',None)=='translation'),
        'termCacheHits':sum(t.translate_cache_call_count for t in translators if getattr(t,'workbench_role',None)=='term'),
        'responsesWithUsage':usage['responses'],'elapsedSeconds':time.monotonic()-started}
    if usage['responses']:
        diagnostics.update(promptTokens=usage['prompt'],completionTokens=usage['completion'])
    emit(type='finished',engine=ENGINE,integration=PROTOCOL,outputs=outputs,requestCount=request_count,contentReport=content_report,diagnostics=diagnostics)
    for selected_translator in translators:
        if getattr(selected_translator,'client',None): selected_translator.client.close()

def error_code(error):
    if isinstance(error,BridgeFailure): return error.code
    name=type(error).__name__
    if name in ('CancelledError','KeyboardInterrupt'): return 'cancelled'
    if name in ('AuthenticationError','PermissionDeniedError'): return 'credential'
    if name=='RateLimitError': return 'rateLimited'
    if name=='NotFoundError': return 'modelUnavailable'
    if name=='ScannedPDFError': return 'scannedDocument'
    if name=='ExtractTextError': return 'textExtraction'
    if name in ('APIConnectionError','APITimeoutError','ConnectError','ReadTimeout'): return 'network'
    if name in ('ValueError','TypeError','KeyError'): return 'configuration'
    return 'processing'

def main():
    parent_pid = os.getppid()
    def watch_parent():
        while True:
            time.sleep(0.5)
            if os.getppid() != parent_pid:
                cancelled.set()
                os._exit(130)
    threading.Thread(target=watch_parent, daemon=True).start()
    signal.signal(signal.SIGTERM,lambda *_: cancelled.set())
    signal.signal(signal.SIGINT,lambda *_: cancelled.set())
    logging.disable(logging.CRITICAL)
    try:
        request=json.loads(sys.stdin.buffer.readline(4*1024*1024))
        # Dependency chatter and raw remote errors must not enter protocol/logs.
        with open(os.devnull,'w') as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            run(request)
    except BaseException as error:
        emit(type='failed',code=error_code(error))
        return 1
    return 0
if __name__=='__main__': sys.exit(main())
