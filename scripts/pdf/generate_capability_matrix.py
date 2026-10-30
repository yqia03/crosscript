#!/usr/bin/env python3
"""Inventory every CLI option and direct API parameter of the locked engine."""
import argparse
import ast
import json
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-dir',type=Path,required=True,help='BabelDOC v0.6.4 source tree; verify its revision before use.')
parser.add_argument('--output-dir',type=Path,required=True,help='Fresh output directory.')
options=parser.parse_args()
options.output_dir.mkdir(parents=True,exist_ok=False)
source=options.source_dir
main=ast.parse((source/'babeldoc/main.py').read_text())
config=ast.parse((source/'babeldoc/format/pdf/translation_config.py').read_text())
cli=[]
for call in ast.walk(main):
    if isinstance(call,ast.Call) and isinstance(call.func,ast.Attribute) and call.func.attr=='add_argument':
        args=[x.value for x in call.args if isinstance(x,ast.Constant)]
        kwargs={x.arg: ast.unparse(x.value) for x in call.keywords}
        cli.append({'flags':args,**kwargs})
api=[]
for node in config.body:
    if isinstance(node,ast.ClassDef) and node.name=='TranslationConfig':
        init=next(x for x in node.body if isinstance(x,ast.FunctionDef) and x.name=='__init__')
        defaults=[None]*(len(init.args.args)-len(init.args.defaults))+init.args.defaults
        api=[{'parameter':a.arg,'default':ast.unparse(d) if d else 'required'} for a,d in zip(init.args.args,defaults) if a.arg!='self']
maintenance={'config','version','debug','warmup','rpc-doclayout','rpc-doclayout2','rpc-doclayout3','rpc-doclayout4','rpc-doclayout5','rpc-doclayout6','rpc-doclayout7','generate-offline-assets','restore-offline-assets','working-dir','metadata-extra-data','enable-process-pool','show-char-box'}
groups={
'T15': 'files lang-in lang-out openai openai-model openai-base-url openai-api-key'.split(),
'T17': 'custom-system-prompt glossary-files no-auto-extract-glossary save-auto-extracted-glossary openai-term-extraction-model openai-term-extraction-base-url openai-term-extraction-api-key openai-term-extraction-reasoning'.split(),
'T18': 'pages output no-dual no-mono dual-translate-first use-alternating-pages-dual watermark-output-mode max-pages-per-part no-watermark only-include-translated-page'.split(),
'T20': 'min-text-length translate-table-text skip-scanned-detection ocr-workaround auto-enable-ocr-workaround disable-graphic-element-process skip-translation only-parse-generate-pdf'.split(),
'T21': 'formular-font-pattern formular-char-pattern split-short-lines short-line-split-factor skip-clean disable-rich-text-translate enhance-compatibility add-formula-placehold-hint primary-font-family no-merge-alternating-line-numbers skip-form-render skip-curve-render remove-non-formula-lines non-formula-line-iou-threshold figure-table-protection-threshold skip-formula-offset-calculation'.split(),
'T22': 'qps ignore-cache pool-max-workers term-pool-max-workers report-interval disable-same-text-fallback enable-json-mode-if-requested send-dashscope-header no-send-temperature openai-reasoning openai-thinking'.split()
}
notes={
'enhance-compatibility':'启用 skip_clean、dual_translate_first、disable_rich_text_translate',
'ocr-workaround':'强制跳过扫描检测、禁用富文本；添加文字背景，不是图片 OCR 识别器',
'auto-enable-ocr-workaround':'开启扫描检测并先关闭手动 OCR workaround；重度扫描时自动选择 workaround',
'only-include-translated-page':'仅指定 pages 时生效',
'no-dual':'与 no_mono 同开会没有 PDF，App 须拒绝',
'no-mono':'App 默认 true（双语）；引擎默认 false（单双语同时输出）',
'no-watermark':'废弃别名；映射 watermark_output_mode=no_watermark',
'pool-max-workers':'未设置时跟随 qps；不是 App 后台名额',
'no-auto-extract-glossary':'默认启用；skip_translation 或 only_parse_generate_pdf 自动关闭',
'save-auto-extracted-glossary':'CLI 默认 false，API 默认 true；App 显式选择避免歧义',
'openai-term-extraction-base-url':'用户明确选择独立服务；App 不继承另一目标 Key',
'openai-term-extraction-api-key':'上游缺省继承主 Key；App 必须依目标隔离，覆盖该默认',
'openai-term-extraction-model':'未设置时主翻译模型',
'openai-term-extraction-reasoning':'仅配置独立 term translator 时生效',
'openai-base-url':'上游未入缓存键，bridge 必须加入 endpoint/profile scope',
'openai-api-key':'仅进程 stdin 内存传递，快照/日志/argv 不得包含',
'openai':'上游 SDK + tenacity 默认重试 429，bridge 须禁用隐式收费重试并拒绝重定向',
'qps':'CLI 默认 4，API 默认 1，App 显式 4；翻译与术语共用限流器',
'only-parse-generate-pdf':'跳过布局、段落、样式和翻译，不能记录为翻译成功',
'skip-translation':'保留布局处理，跳过翻译；不能记录为翻译成功',
'non-formula-line-iou-threshold':'仅 remove_non_formula_lines 时生效；0..1',
'figure-table-protection-threshold':'仅 remove_non_formula_lines 时生效；0..1',
'short-line-split-factor':'仅 split_short_lines 时生效',
'send-dashscope-header':'仅明确使用兼容该请求头的服务；上游说明跳过供应商内容检查',
'openai-thinking':'enabled/disabled；需对应服务支持；默认不发',
'translate-table-text':'0.6.4 CLI 残留开关导入已不存在的 RapidOCR；API table_model 明确忽略，不能宣称可用',
}
lines=['# T15 / V4：BabelDOC 0.6.4 全量能力矩阵','',
'锁定来源：`v0.6.4` / `17480db9df92ddcb37349ce34b312335226e8ec9`。集成层为本仓库 `babeldoc_bridge.py` 协议 v1，直接使用 Python API，不使用缺参包装层。此表从锁定源码 AST 自动盘点；状态分开记录，不将映射等同运行通过。','',
'CLI 每一项（包括维护和废弃入口）均列出，随后补齐直接 API 参数。入口为实施归属；V4 不预先标记 T16–T22 完成。','',
'| 参数 | 上游默认 | 依赖/冲突 | 实验/状态 | App 入口/适配 | 归属 | 证据 |',
'| --- | --- | --- | --- | --- | --- | --- |']
for row in cli:
    flags=row['flags']; name=next((x[2:] for x in flags if x.startswith('--')),flags[0])
    group=next((k for k,v in groups.items() if name in v), None)
    if name not in maintenance and not group: raise RuntimeError('Unclassified '+name)
    group=group or 'T16/T22'
    default=row.get('default', 'false' if row.get('action')=="'store_true'" else 'None')
    helptext=row.get('help','')
    status='实验性' if 'experimental' in helptext or name in ['split-short-lines','add-formula-placehold-hint'] else '常规'
    entry='App 托管/诊断；不提供任意环境部署入口' if name in maintenance else {'T15':'PDF 常用设置','T17':'PDF 术语与提示','T18':'PDF 输入输出','T20':'PDF 扫描与内容','T21':'PDF 版式与兼容','T22':'PDF 速度与缓存'}[group]
    if name=='translate-table-text': status='已废弃/失效';entry='显示版本限制，不提供假开关'
    note=notes.get(name,'见上游帮助；无额外已知互斥')
    evidence='源码核查；运行待相应任务'
    lines.append('| `'+', '.join(flags)+'` | `'+default.replace('|','\\|')+'` | '+note+' | '+status+' | '+entry+'；直接 API 映射 | '+group+' | '+evidence+' |')
lines+=['','## 直接 API 完整签名补充','','CLI 与 API 默认不同时，App 必须显式固定。内部注入项不产生新的用户入口。','', '| API 参数 | 默认 | 映射/状态 |','| --- | --- | --- |']
cli_names={next((x[2:] for x in row['flags'] if x.startswith('--')),row['flags'][0]).replace('-','_') for row in cli}
special={'font':'已忽略，字体族入口 primary_font_family；不提供无效自定义文件开关','table_model':'已废弃并强制 None，表格段落继续按核心正常段落管线处理；独立模型开关失效','use_side_by_side_dual':'兼容别名；false 且未选 alternating 时映射交替页','doc_layout_model':'App 托管 ONNX 模型，T16','translator':'T14 ProviderSnapshot + 目标隔离凭据','term_extraction_translator':'T17 独立服务快照/目标隔离凭据，缺省复用同目标 translator','glossaries':'T17 多份 Glossary objects / CSV 校验','split_strategy':'T18 PageCountStrategy(max_pages_per_part)','progress_monitor':'T19 bridge 注入与取消','use_rich_pbar':'CLI 终端渲染；App 关闭，以 JSONL 进度替代','enable_graphic_element_process':'disable_graphic_element_process 取反','merge_alternating_line_numbers':'no_merge_alternating_line_numbers 取反','input_file':'App 独立资料副本，T15','output_dir':'App 结果暂存后提交，T15/T18','auto_extract_glossary':'no_auto_extract_glossary 取反'}
for row in api:
    name=row['parameter'];maptext=special.get(name,'对应 CLI 参数；按所属任务实现' if name in cli_names else '内部配置；由 bridge 固定')
    lines.append(f"| `{name}` | `{row['default']}` | {maptext} |")
(options.output_dir/'upstream-capability-matrix.md').write_text('\n'.join(lines)+'\n')
(options.output_dir/'upstream-capabilities.json').write_text(json.dumps({'engine':'0.6.4','sha':'17480db9df92ddcb37349ce34b312335226e8ec9','cli':cli,'api':api},indent=2)+'\n')
print(f'CLI {len(cli)} options; API {len(api)} parameters; all classified')
