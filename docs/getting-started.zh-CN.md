# 安装与使用 Crosscript build 5

[English](getting-started.md) · [项目首页](../README.zh-CN.md) · [Release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5)

本说明对应已发布的 Apple Silicon 预览版 **0.1.0 (5)**。已签名显示名称为 **翻译工作台**，包／可执行文件沿用 `TranslationWorkbench`，Bundle ID 为 `dev.uown.translation-workbench`。这些名称没有迁移，不要按 Crosscript 品牌猜测资料目录。

## 下载、校验与打开

1. 下载 [Crosscript-preview-0.1.0-5.zip](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-preview-0.1.0-5.zip)，大小为 169,789,128 bytes。在文件所在目录用终端执行：

   ```sh
   shasum -a 256 Crosscript-preview-0.1.0-5.zip
   ```

   预期 SHA-256：`86b4693ce411664cfe388e29efe09280ec22ab6f696701baf1854d536f590f97`，同时与同版 Release 核对。摘要只能证明字节一致性，不验证发行者身份。若下载完整 28 项资产并使用 `SHA256SUMS.txt`，请先按 Release 的五项命名映射恢复清单原名；GitHub 上五个 ASCII 下载名与原中文名不同。
2. 先退出旧版并备份需要保留的资料。用 Finder 解压，把 `TranslationWorkbench.app` 放入选定的应用程序目录（如 `/Applications`），正常打开 `.app`。目标为 Apple Silicon 与 macOS 14.2+；最低系统 macOS 14.2 尚未实机验证。
3. 本预览版只有 **ad-hoc 完整性签名**，没有 Developer ID 发行者认证或 Apple 公证。如果系统阻止未识别／未公证应用，请参考 [Apple 单应用打开说明](https://support.apple.com/en-us/102445)。若“系统设置 → 隐私与安全性”提供“仍要打开”，是否采用该单应用例外由你决定，设备策略也可能限制此操作。不要关闭全局保护、删除 quarantine 或重签应用。摘要／签名不符，或出现恶意软件、被修改／损坏提示时应停止，并保留提示原文用于脱敏反馈。
4. 在设置中选择英文／简体中文并添加服务。安装应用不附带服务账户、API 额度或密钥。

**实际安装证据：** build 5 第二台 Mac B01–B06 未执行，维护者于 2026-10-30 明确豁免并批准发布。本说明不代表二机安装、权限流程或运行时冷下载已通过，也不继承 build 4 验收。

Release 提供[冻结的安装／卸载参考](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/INSTALL-UNINSTALL-LIMITATIONS.zh-CN.md)、manifest 和静态核验脚本。参考中的“尚未发布／必须二机补验”记录较早的准备状态，后续批准与豁免以 Release 为准；技术路径与钥匙串范围仍可参考。静态完整性不等于 Gatekeeper、启动或完整工作流验收。

## 配置服务、数据流与费用

在设置中添加自己的服务。文本与 PDF 可分别选择默认配置，共用提示词与术语表。密钥保存在 macOS 钥匙串，按服务／目标隔离；保存时留空保留已有密钥，删除应使用相应的移除密钥控件。

| 工作流 | 配置 | 内容与费用 |
| --- | --- | --- |
| 文本 / Markdown | OpenAI-compatible 地址、模型、密钥，选择文本默认服务 | 明确提交后把原文与翻译指令发送到该地址；本机源语言检测本身不翻译。 |
| PDF | 所选 PDF／文本服务；BabelDOC 托管组件 | 翻译时把提取文字与相关指令发送给服务商；本机环境准备与服务处理分别进行。 |
| 录后转写 | 固定 OpenAI 或 AiHubMix 预设与该服务的密钥 | 明确发起转写后发送音频，本机保留录音／导入副本；不提供任意音频端点或模型。 |
| 实时双语字幕 | 单独 Gemini Live 密钥与配置 | 会话中发送音频，本机保留录音及双语文字；文本兼容端点／凭据不等于支持 Gemini。 |

服务调用、连接检查、重试及失败／不完整结果都可能计费。实时模型即使只在应用显示文字，也可能生成计费音频。价格、模型／账户权限、内容留存和额度取决于所选服务商；本应用不提供固定价格或通用兼容保证。发送敏感内容前请核对服务商政策。

录音在需要时请求相应 macOS 权限，每次选择一种来源：麦克风（默认或指定设备）、整台电脑声音或指定应用。屏幕／系统音频权限用于音频采集，应用不保留屏幕画面。

## PDF 首次组件准备

App 管理 `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`（含 Python 3.12.15）。普通打包应用的用户不需要另装 Python、Homebrew、Xcode 或编译器。

267 个固定输入中，22 个内置于 App（20 个改名字体、2 个修改 wheels），另有 **245 个 HTTPS 输入，共 359,471,768 bytes**。这只是剩余下载载荷，不是总磁盘占用，还需展开、安装、临时处理和 PDF 空间。App 显示准备进度、核对字节并复用环境。失败时保留错误，通过正常重试恢复；不要搬用别的机器缓存、覆盖受管库或改 inventory 绕过检查。历史离线安装用固定本地输入验证，不等于二机真实冷下载。

## 工作、历史与导出

| 工作流 | 开始／重开 | 保存与导出 |
| --- | --- | --- |
| 文本 / Markdown | 输入原文、选择方向和格式，按翻译或 Enter 提交，Shift+Enter 换行；每次提交形成独立历史。打开历史恢复工作区，不会重新调用服务。 | 编辑译文，从操作菜单导出原文、TXT 或 Markdown；双语 Markdown 要求当前原文／方向／格式与结果一致，更改输入后可能需要再次明确翻译。工作区编辑不改写既有历史条目。 |
| PDF | 导入 PDF、选择选项并明确发起翻译，从历史重开资料。移出工作区列表不删除历史，也不取消任务。 | 预览并导出可用的单语／双语结果；重新处理保留旧结果。不保证扫描图片 OCR 或复杂版式／公式／字体无损。 |
| 录音 | “新建项目”只打开空白工作区，不录音、不上传、不请求权限。开始录音或导入后，主动发起录后转写；从历史选择结果并按可用时间回听。 | 用相应控件编辑、复制、导出所选转写；重新转写保留旧结果及编辑。需要独立备份时保留原音频和导出文件。 |
| 实时字幕 | 配置 Gemini、选择音源后明确开始；可使用主视图或独立字幕窗，之后重开录音及双语历史。 | 编辑、复制或导出双语 TXT。文字缺口不等于本地音频丢失；补齐须明确发起，并有独立服务及验证边界。 |

文件处理后台最多同时运行一项，交互式文本翻译独立。新服务请求可能收费；打开历史、编辑及本地保存／导出本身不重新提交翻译。

## 限制与反馈

[首页逐工作流证据表](../README.zh-CN.md#资料费用与验证边界)区分历史验证与缺口。官方 OpenAI 成功转写未验证，AiHubMix 记录不覆盖所有预设；Gemini 长会话、真实断线恢复和真实文件补齐仍有缺口。此前停止的 PDF 批次和实时／付费探测保持停止，本轮文档更新没有执行新的真实服务验收。

帮助或 bug 请用 [GitHub Issues](https://github.com/yqia03/crosscript/issues/new)，提供应用／build、macOS、芯片、工作流、服务／模型、复现步骤及脱敏错误。去除密钥、私人文档／音频和机器路径。安全问题用[私密漏洞报告](https://github.com/yqia03/crosscript/security/advisories/new)，见 [SECURITY.md](../SECURITY.md)。本项目由个人维护，不承诺响应时限。

## 卸载或移除本机资料

先停止并保存工作、结束／取消任务、备份需要的资料。删除 `TranslationWorkbench.app` 会保留资料、偏好与钥匙串凭据，便于重装，不会撤销服务商密钥。

默认资料根是 `~/Library/Application Support/TranslationWorkbench/Recordings/`；若用了 `--data-directory`，以实际指定目录为准。该根包含录音、`TextWorkspace/`（以及可能保留的旧 `TextMaterials/`）、`PDFMaterials/`、配置与 `PDFRuntime/`。只清理 PDF 组件时应单独识别 `PDFRuntime/`，避免误删整个资料根。偏好域为 `dev.uown.translation-workbench`。

优先使用 App 针对目标的移除密钥控件。Keychain service 为 `TranslationWorkbench.TextPDFProviders` 与 `TranslationWorkbench.OpenAIAudio`（后者也包括 Gemini）。删除本机凭据不等于服务商撤销；外部原件、导出、备份与云端留存分别管理。本轮没有执行卸载、删除、安全擦除或“零残留”验证，详细路径／账户范围见冻结安装参考。
