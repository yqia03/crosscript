#!/usr/bin/env python3
"""Join the pinned source inventory with reviewed App mappings; no network access."""
import argparse
import json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--inventory',type=Path,default=Path(__file__).with_name('pins')/'upstream-capabilities.json')
parser.add_argument('--output-dir',type=Path,required=True,help='Fresh output directory; generated mappings are not release acceptance evidence.')
args=parser.parse_args()
args.output_dir.mkdir(parents=True,exist_ok=False)
inventory=json.loads(args.inventory.read_text())
rows={}
def add(name,default,entry,dependency,owner,evidence,state='正常'):
    rows[name]={'appDefault':default,'entry':entry,'dependencies':dependency,'state':state,'owner':owner,'evidence':evidence}
def group(owner,evidence,definitions):
    for args in definitions:add(*args,owner,evidence)
group('T15','E15',[
('files','用户选择','导入 PDF（可多选）→逐份托管副本','一份输入对应独立资料/任务；源文件移动不影响历史'),
('lang-in','en','方向：英→中 / 中→英→lang_in','与目标语言成对选择；本产品已确认英中双向，未宣称任意语言验收'),
('lang-out','zh','方向：英→中 / 中→英→lang_out','与源语言成对选择；本地生成也保留方向快照'),
('openai','选定兼容服务适配器','服务配置→真实 OpenAITranslator','本地仅解析/排版不构造网络客户端；无自动换服务'),
('openai-model','选定配置模型','服务配置→model','不继承上游 gpt-4o-mini 默认；真实 DeepSeek 已验 deepseek-flash'),
('openai-base-url','选定配置地址','服务配置→base_url','绑定profileUUID+规范化目标；拒绝redirect；目标加入缓存键'),
('openai-api-key','无缺省Key','服务配置安全存储→stdin内存','精确目标凭据；不入argv/快照/日志；缺失不挪用其他Key')])
group('T18','E18',[
('pages','全部','输入输出→页范围→pages','1基序号、逗号/闭区间/开放区间；按真实源页数验证'),
('output','App托管结果目录','阅读输出→保存副本；引擎output_dir固定为任务暂存','不得写回外部原件；保存失败保留待保存输出'),
('no-dual','false','输出类型→译文/双语/两者→no_dual','禁止no_dual与no_mono同时true；本地标单栏/对照'),
('no-mono','true','输出类型→译文/双语/两者→no_mono','App缺省仅双语；引擎缺省false会同时生成两种'),
('dual-translate-first','false','对照→译文在前→dual_translate_first','仅对照输出有效；增强兼容在非parseOnly强制true'),
('use-alternating-pages-dual','false','对照布局→并排/交替→use_alternating_pages_dual','原文/译文顺序按translatedFirst；交替页数翻倍'),
('watermark-output-mode','watermarked','水印→带/不带/两种→WatermarkOutputMode','parseOnly仅no_watermark；两种时必须返回完整四/二输出集'),
('max-pages-per-part','不拆分','分部→每部页数→split_strategy','正整数；顺序合并结果；所选页不含首部也保留水印变体'),
('no-watermark','false','水印→不带水印（统一现代参数）','等价watermark_output_mode=no_watermark；不另建重复开关'),
('only-include-translated-page','false','仅输出所选页→only_include_translated_page','必须先填写页范围；否则拒绝')])
rows['no-watermark']['state']='废弃别名；等效入口保留'
group('T20','E20',[
('min-text-length','5','扫描与内容→最短文字长度→min_text_length','非负整数；过高可全部保留原文，界面明确提示'),
('translate-table-text','不启用','版本能力说明：普通文字表格仍经布局处理','0.6.4 CLI引用缺失RapidOCR，API明确忽略table_model；不得提供假识别开关'),
('skip-scanned-detection','false','扫描模式→跳过检测→skip_scanned_detection','互斥选择；只有已有文字层可翻译，不是OCR识别'),
('ocr-workaround','false','扫描模式→强制OCR兼容→ocr_workaround','强制skip_scanned_detection，关闭富文本/非公式线条移除；不是图片文字识别'),
('auto-enable-ocr-workaround','false','扫描模式→自动OCR兼容→auto_enable_ocr_workaround','开扫描检测、初始关闭强制兼容；检测到重度扫描后触发兼容'),
('disable-graphic-element-process','false','处理图形→enable_graphic_element_process取反','仅影响处理页；parseOnly绕过该布局阶段'),
('skip-translation','false','处理方式→仅排版→skip_translation','本地无provider/Key/HTTP/提取；保留布局处理，结果标未翻译'),
('only-parse-generate-pdf','false','处理方式→仅解析生成→only_parse_generate_pdf','本地无provider/Key/HTTP；跳过布局/字体/公式规则；无水印，表单/曲线仍有效')])
rows['translate-table-text']['state']='上游失效/废弃；有明确版本限制'
rows['ocr-workaround']['state']='上游实验性'
group('T21','E21',[
('formular-font-pattern','空=引擎默认','字体公式→公式字体规则→Python regex','≤4096bytes；非法规则在服务前拒绝；parseOnly保留草稿但不校验/发送'),
('formular-char-pattern','空=引擎默认','字体公式→公式字符规则→Python regex','≤4096bytes；补充内置识别；parseOnly禁用；过宽会漏翻普通文字'),
('split-short-lines','false','字体公式→拆分短行→split_short_lines','parseOnly禁用；可能损害段落/版式，不保证改善'),
('short-line-split-factor','0.8','拆分短行→宽度系数→short_line_split_factor','有限正数；拆分启用时有效；parseOnly不校验/发送'),
('skip-clean','false','版式兼容→跳过清理→skip_clean','增强兼容强制true；parseOnly禁用'),
('disable-rich-text-translate','false','版式兼容→富文本翻译（取反）','增强兼容/强制OCR关闭；parseOnly禁用；不能保证局部粗斜体'),
('enhance-compatibility','false','版式兼容→增强兼容→enhance_compatibility','强制skip_clean、disable_rich_text_translate、dual_translate_first；parseOnly不生效'),
('add-formula-placehold-hint','false','字体公式→公式占位提示→add_formula_placehold_hint','额外提示模型保留公式；parseOnly禁用；上游不推荐默认开启'),
('primary-font-family','自动(None)','字体→自动/衬线/无衬线/手写→primary_font_family','使用已校验托管字体；parseOnly禁用'),
('no-merge-alternating-line-numbers','false（实际merge=true）','版式→合并交错行号→merge_alternating_line_numbers取反','parseOnly禁用；CLI inventory默认True是目标merge字段'),
('skip-form-render','false','绘制表单对象（取反）→skip_form_render','parseOnly仍生效；关闭可能删除处理页嵌入图形'),
('skip-curve-render','false','绘制曲线（取反）→skip_curve_render','parseOnly仍生效；关闭可能删除表格线/装饰线'),
('remove-non-formula-lines','false','版式→移除非公式线条→remove_non_formula_lines','OCR兼容关闭；parseOnly禁用'),
('non-formula-line-iou-threshold','0.9','线条→段落重叠阈值→non_formula_line_iou_threshold','0…1；移除线条启用时有效；parseOnly不校验/发送'),
('figure-table-protection-threshold','0.9','线条→图表保护阈值→figure_table_protection_threshold','0…1；移除线条启用时有效；parseOnly不校验/发送'),
('skip-formula-offset-calculation','false','计算公式偏移（取反）→skip_formula_offset_calculation','parseOnly禁用；复杂公式效果取决于样本')])
for name in ['split-short-lines','add-formula-placehold-hint']:rows[name]['state']='上游实验性'
group('T17','E17',[
('custom-system-prompt','未选择','共享提示词库→选择预设→custom_system_prompt','快照冻结内容；本地模式不发送；与术语表分别管理'),
('glossary-files','未选择','共享术语库→多选命名表/CSV导入→Glossary集合','保留语言过滤、稳定UUID；同名表不互相覆盖；快照冻结'),
('no-auto-extract-glossary','false（实际auto_extract=true）','自动提取术语（取反）→auto_extract_glossary','关闭时不读取提取Key/不发请求；本地模式强制false'),
('save-auto-extracted-glossary','false','保存提取CSV→save_auto_extracted_glossary','仅自动提取有效；生成独立CSV，可导出/明确加入共享库；不自动覆盖'),
('openai-term-extraction-model','同明确主目标模型','提取服务→当前/独立配置→model','独立目标必须有对应Key，不借主服务Key'),
('openai-term-extraction-base-url','同明确主目标地址','提取服务→独立配置→base_url','独立目标绑定profileUUID与endpoint；非自动换服务'),
('openai-term-extraction-api-key','同明确主目标匹配Key','提取服务配置安全存储→stdin内存','独立目标不继承主Key；缺失在任务运行前失败'),
('openai-term-extraction-reasoning','无','独立提取→推理字段→reasoning','仅明确独立提取配置可设置；≤200字符无控制符；服务须支持')])
group('T22','E22',[
('qps','4','速度缓存→每秒请求→qps','1…100；翻译/提取共用限流；API默认1被显式4覆盖；本地禁用'),
('ignore-cache','false','速度缓存→绕过缓存→ignore_cache','同时跳过读写；命中不产生usage；目标/模型/语言/提示/选项隔离'),
('pool-max-workers','继承QPS','速度缓存→翻译线程→pool_max_workers','1…100或空；仅引擎内部并发，不增加App后台名额'),
('term-pool-max-workers','继承翻译线程','速度缓存→提取线程→term_pool_max_workers','1…100或空；关闭提取时保留草稿但不校验/发送'),
('report-interval','0.1秒','速度缓存→进度间隔→ProgressMonitor(report_interval)','0.05…60秒；阶段边界仍报告，非服务QPS'),
('disable-same-text-fallback','false','兼容→相同原文回退（取反）','可增加正常翻译请求；受同一任务请求上限约束'),
('enable-json-mode-if-requested','false','兼容→按需JSON→enable_json_mode_if_requested','只在上游请求JSON时发送response_format；需服务支持'),
('send-dashscope-header','false','兼容→DashScope检查头→send_dashscope_header','有供应商适用范围；DeepSeek首样本未验证该选项'),
('no-send-temperature','false（实际send=true）','兼容→发送温度0（取反）→send_temperature','取消时请求无temperature；供应商可能有自己的约束'),
('openai-reasoning','无','兼容→推理字段→reasoning','≤200bytes无控制符；并非所有模型支持；local禁用'),
('openai-thinking','不发送','兼容→默认/启用/关闭→thinking.type','不是自动换模型；真实DeepSeek首样本仅默认范围'),
('debug','false','诊断→诊断PDF→debug','日志仍抑制；输出包含源文和诊断标记，属于本地资料'),
('show-char-box','false','诊断→字符框→show_char_box','只有诊断PDF启用才生效；保留本地源内容，不是无内容诊断')])
rows['show-char-box']['state']='上游debug-only；显式高级入口'
group('T16/T22','EM',[
('config','App快照','无任意配置文件入口；以类型化任务快照代替CLI TOML','维护/配置机制；不能绕过目标凭据和输入校验'),
('version','0.6.4 / protocol 1','组件状态与结果版本','精确版本检查；不匹配拒绝运行'),
('warmup','进入PDF自动准备','组件准备→下载/校验/安装/真实模型加载','267资源592025062bytes；无需系统Python；失败可重试'),
('generate-offline-assets','不暴露手工打包','组件准备使用固定manifest资产分发','上游部署维护工具；不扩为用户功能，不声明CLI打包已测'),
('restore-offline-assets','不暴露任意包导入','组件准备使用校验资源缓存复用','只接受manifest校验资源；不声明任意离线包导入'),
('working-dir','每任务托管暂存','App自动分配workingDirectory','取消/待保存/退出遵守资料生命周期；不能自选覆盖原件'),
('metadata-extra-data','None','无任意metadata入口；版本/参数由结果快照保存','上游诊断/部署元数据扩展，不是用户翻译功能；未声明任意字符串支持'),
('enable-process-pool','false','不启用上游开发多进程','源码声明Development and Testing ONLY；取消边界为一个受控子进程')])
for n in ['config','generate-offline-assets','restore-offline-assets','metadata-extra-data','enable-process-pool']:rows[n]['state']='维护/部署范围；明确未暴露'
for i in range(1,8):
 n='rpc-doclayout'+(str(i) if i>1 else '')
 add(n,'None','无远程布局部署入口；使用锁定本地ONNX模型','任意RPC部署不扩为用户功能；无调用/可用性声明','T16/T22','EM','维护/部署范围；明确未暴露')
api_special={
 'translator':'openai','input_file':'files','doc_layout_model':'warmup','output_dir':'output','working_dir':'working-dir',
 'split_strategy':'max-pages-per-part','glossaries':'glossary-files','auto_extract_glossary':'no-auto-extract-glossary',
 'enable_graphic_element_process':'disable-graphic-element-process','merge_alternating_line_numbers':'no-merge-alternating-line-numbers',
 'term_extraction_translator':'openai-term-extraction-model'}
api_extra={
 'enable_graphic_element_process':dict(rows['disable-graphic-element-process'], appDefault='true', entry='扫描与内容→处理图形→enable_graphic_element_process直接映射'),
 'auto_extract_glossary':dict(rows['no-auto-extract-glossary'], appDefault='true', entry='自动提取术语→auto_extract_glossary直接映射'),
 'merge_alternating_line_numbers':dict(rows['no-merge-alternating-line-numbers'], appDefault='true', entry='版式→合并交错行号→merge_alternating_line_numbers直接映射'),
 'term_extraction_translator':dict(rows['openai-term-extraction-model'], appDefault='同明确主目标的独立Translator实例', entry='提取服务→同目标或明确独立目标的Translator实例'),
 'doc_layout_model':dict(appDefault='锁定本地ONNX DocLayoutModel',entry='组件准备/真实模型加载→DocLayoutModel.load_onnx()',dependencies='按manifest校验权重；不需要RPC服务；组件失败保留资料',state='本地模型适配',owner='T16',evidence='EM'),
 'font':dict(appDefault='None（源码忽略）',entry='不暴露任意字体路径；有效字体选择见primary_font_family',dependencies='TranslationConfig直接self.font=None；不能称任意自选字体生效',state='废弃/源码忽略',owner='T21',evidence='E21'),
 'use_rich_pbar':dict(appDefault='false',entry='任务进度UI取代终端rich进度条',dependencies='JSONL协议不混入终端输出',state='界面适配',owner='T15/T22',evidence='E15/E22'),
 'progress_monitor':dict(appDefault='真实ProgressMonitor实例',entry='队列进度与取消→threading.Event和JSONL',dependencies='同步do_translate实际返回才终结，避免异步callback挂起；取消必须实际进程退出',state='界面适配',owner='T15/T22',evidence='E15/E22'),
 'use_side_by_side_dual':dict(appDefault='true',entry='并排/交替布局使用现代use_alternating_pages_dual',dependencies='旧false会启用交替以兼容；不同时暴露两个矛盾开关',state='废弃兼容参数',owner='T18',evidence='E18'),
 'table_model':dict(appDefault='None（源码忽略）',entry='版本能力说明；普通文字表格仍处理',dependencies='源码警告deprecated and ignored；专用RapidOCR不可用',state='废弃/源码忽略',owner='T20',evidence='E20')}
result=[]
for item in inventory['cli']:
 flag=next(f for f in item['flags'] if f.startswith('--')); name=flag[2:]
 assert name in rows,name
 default=item.get('default', 'False' if item.get('action')=="'store_true'" else 'None')
 result.append({'surface':'CLI','parameter':', '.join(item['flags']),'upstreamDefault':default,**rows[name]})
for item in inventory['api']:
 name=item['parameter'];mapping=api_special.get(name,name.replace('_','-'))
 info=api_extra[name] if name in api_extra else rows[mapping]
 result.append({'surface':'API','parameter':name,'upstreamDefault':item['default'],**info})
assert len(result)==133 and len(rows)==77,(len(result),len(rows))
base=args.output_dir
(base/'capability-map.json').write_text(json.dumps({'engine':inventory['engine'],'upstreamSHA':inventory['sha'],'cliCount':77,'apiCount':56,'rows':result},ensure_ascii=False,indent=2)+'\n')
head='''# PDF capability mapping (preparation material)

This maps the pinned BabelDOC 0.6.4 API and CLI inventory to the application integration. T/E labels are historical mapping identifiers, not links to public acceptance evidence. Mapping coverage does not prove current runtime behavior, live service quality, installation acceptance or release readiness. See capability-map.json for exact rows.

'''
for surface in ['CLI','API']:
 head+=f'## {surface} 全量条目\n\n| 参数 | 上游默认 | App默认 | App入口 / 适配 | 依赖、冲突与限制 | 状态 | 任务 | 证据 |\n|---|---|---|---|---|---|---|---|\n'
 for row in result:
  if row['surface']!=surface:continue
  vals=[f"`{row['parameter']}`",f"`{row['upstreamDefault']}`",row['appDefault'],row['entry'],row['dependencies'],row['state'],row['owner'],row['evidence']]
  head+='| '+' | '.join(str(v).replace('|','／').replace('\n',' ') for v in vals)+' |\n'
 head+='\n'
head+='\nThese mappings retain historical scope notes. Fresh release-specific checks remain required; Developer ID and notarization are not requirements for the planned ad-hoc preview.\n'
(base/'pdf-capabilities.md').write_text(head)
print('Mapped 77 CLI entries + 56 API parameters; no unowned inventory entries.')
