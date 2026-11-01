# Crosscript

**面向 macOS 的翻译工作台** · [English](README.md)

面向 Apple Silicon Mac 的原生翻译与转写工作台。使用自己的 API Key 翻译文本、Markdown 和 PDF，转写录音并查看实时双语字幕。原始资料与可编辑结果保存在本机；云端处理会把任务所需内容发送给你选择的服务。

**已发布预览版：[0.1.0 build 5 / v0.1.0-preview.5](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5)。** 本版采用 ad-hoc 完整性签名，未经 Apple 公证，也没有 Developer ID 发行者认证。build 5 第二台 Mac B01–B06 检查**未执行**；维护者于 2026-10-30 明确豁免该门槛并批准发布。豁免不等于安装测试通过。

## 下载与安装

从同版 Release 下载 [Crosscript-preview-0.1.0-5.zip](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-preview-0.1.0-5.zip)。该 Release 同时提供精确源码归档、第三方源码／构建材料及校验清单。[安装与使用说明](docs/getting-started.zh-CN.md)覆盖校验、首次打开限制、服务配置、历史、导出和卸载。

- **硬件：** Apple Silicon（arm64），目前没有 Intel 版。
- **系统目标：** macOS 14.2 或更新；尚未在最低版本 macOS 14.2 实机验证。
- **界面：** 简体中文与英文。
- **应用名称：** 下载的包为 `TranslationWorkbench.app`，已签名显示名称为 **翻译工作台**。Crosscript 是项目／发行品牌，内部名称和资料路径仍沿用 TranslationWorkbench。
- **首次打开：** 用 Finder 解压，将应用放入选定的应用程序目录并正常打开。未公证应用可能被 macOS 阻止；按使用说明中的适用单应用系统流程处理，若出现完整性、恶意软件或损坏提示则停止。
- **PDF 准备：** App 内置 22 个输入，另有 245 个固定 HTTPS 输入首次下载，共 359,471,768 bytes（约 359 MB）；还需展开、安装和处理空间。Python 由 App 管理，普通用户无需另装 Homebrew、Xcode 或 Python。

## 四条工作流

| 工作流 | 使用与保留结果 | 服务边界 |
| --- | --- | --- |
| 文本 / Markdown | 明确提交、原译文对照、编辑、独立历史，导出 TXT、Markdown 或双语 Markdown | 配置的 OpenAI-compatible 文本地址与模型 |
| PDF 翻译 | BabelDOC 托管运行时、单语／双语 PDF、预览、历史及导出；共用提示词和术语表 | 所选 PDF／文本服务 |
| 录音与录后转写 | 麦克风或系统声音（含指定应用）、音频导入、编辑、回听及导出；每次录音一种音源 | 固定 OpenAI / AiHubMix 预设，不提供任意音频地址或模型 |
| 同声传译（实时双语字幕） | Gemini Live 原文与译文、可选独立字幕窗、本地录音及可编辑双语历史 | 单独适配的 Gemini Live 协议与凭据 |

先在设置中配置服务与自己的密钥，文本与 PDF 可选不同默认配置。文本翻译使用文本默认服务，按翻译按钮或 Enter 提交，Shift+Enter 换行。打开历史、编辑文字和保存设置本身不提交翻译。文件任务共用后台队列，交互式文本翻译仍可使用。

## 资料、费用与验证边界

密钥存于 macOS 钥匙串。原始录音、导入副本及结果保存在本机，直至你主动删除。明确翻译、转写、连接检查或同传可能向服务商发送内容并产生费用，失败或不完整结果也可能计费。本地保存不等于离线处理；Gemini 即使只在应用显示文字，也可能产生计费音频。发送内容前请核对所选服务的价格、留存政策与账户限制。

| 工作流／平台 | 已有证据与剩余边界 |
| --- | --- |
| 文本 / Markdown | 保留现有实现及限定历史检查；OpenAI-compatible 不证明每个服务、模型、参数或语言都已验证。本轮没有新增云端服务验收。 |
| PDF | 有聚焦离线安装／复用和组件证据，不等于另一台 Mac 冷下载或任意 PDF 质量验证。此前部分完成的 PDF 批次保持停止；扫描图片不会自动获得 OCR，版式、公式和字体可能改变。 |
| 录后转写 | AiHubMix 有历史真实使用记录；官方 OpenAI 成功转写及各预设时间定位精度尚未全部建立证据。 |
| Gemini Live | 有短时历史真实服务验证；长会话、真实断线恢复和文件补齐仍有缺口，不声称真实 Gemini 文件补齐成功；不承诺译文语音或固定延迟。 |
| 全应用／安装 | 许可组件和包装检查只覆盖各自范围。build 5 第二台 Mac B01–B06 未执行且已豁免，不继承 build 4 验收；macOS 14.2 实机与完整工作流验收仍未覆盖。 |

语言菜单不等于逐语言质量保证，初始验证重点为简体中文和英文。此前停止的 PDF 批次、实时／付费探测没有恢复。见 [build 5 当前证据与用户材料范围](docs/release-verification/build5/user-materials.md)。

## 源码、贡献与支持

- [反馈问题／请求帮助](https://github.com/yqia03/crosscript/issues/new)：附应用版本／build、macOS、芯片、工作流、服务／模型和脱敏复现步骤，见[贡献指南](CONTRIBUTING.md)。
- [私密报告漏洞](https://github.com/yqia03/crosscript/security/advisories/new)：见 [SECURITY.md](SECURITY.md)，不要在公开 issue 贴凭据或可利用的安全细节。
- 同版提供[精确 build 5 源码](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-source-0.1.0-5.tar.gz)与[第三方材料](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz)。GitHub 自动生成的源码 ZIP 不替代与 App 绑定的源码归档。

项目由个人维护，不承诺响应时限。开发构建需要 Apple Silicon、Swift 6 与 macOS SDK，见[源码／构建说明](docs/source-and-build.md)和[测试范围](docs/testing.md)。当前文档更新不重建或修改已冻结的 build 5 标签、App 或 28 项资产；其中的历史“待发布”文字按 Release 中后续批准与豁免解释。

## 许可证

自有代码采用 **AGPL-3.0-only**，见 [LICENSE](LICENSE) 与[贡献条款](CONTRIBUTING.md)。允许遵守许可条件的商用、修改和再分发，并适用对应源码及远程网络交互要求。第三方组件保留各自许可，见[第三方通知](THIRD_PARTY_NOTICES.md)、[PDF 组件声明](app/macos/Sources/TranslationWorkbench/Resources/PDF/Notices/README.md)及[分发材料](docs/distribution-materials.md)。材料可取得不等于每项原生产构建已复现或整栈法律结论。
