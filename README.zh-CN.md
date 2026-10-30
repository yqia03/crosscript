# Crosscript

**Translation Workbench for macOS**

[English](README.md) · 简体中文

面向 Apple Silicon Mac 的原生翻译与转写工作台。使用你自己的 API Key，翻译文本、Markdown 和 PDF，转写录音，并查看实时双语字幕；原始资料与可编辑结果保存在你的 Mac 上。

这是一个从个人日常需求出发、由个人维护的项目，希望也能帮助有相似需求的人。

## 发布状态

**0.1.0 预览版正在准备，尚未公开发布，目前没有公开安装包下载。** 项目自有代码采用 AGPL-3.0-only；计划在源码审查、第三方分发材料和普通用户安装验证完成后，将源码与未做 Developer ID 签名／Apple 公证的预览包一起首发。

当前仓库中的本地开发包不等于正式发行包。待完成事项见[发布准备清单](docs/release-preparation.md)。

预览包计划使用无需开发者证书的 ad-hoc 签名做完整性校验，不提供已验证的发行者身份或 Apple 公证票据。macOS 可能阻止首次打开；届时提供 Apple 官方针对单个应用的“仍要打开”步骤及适用限制，另一台 Mac 的实际安装仍待验证。见 [Apple 说明](https://support.apple.com/en-us/102445)。

## 可以做什么

| 工作流 | 能力 | 服务与使用边界 |
| --- | --- | --- |
| 文本与 Markdown 翻译 | 原文/译文对照、译文编辑、独立翻译历史、复制、单语及双语 Markdown 导出；共用提示词和术语表。 | 使用设置中的文本默认服务。按翻译按钮或 Enter 明确提交，Shift+Enter 换行；采用非流式请求，收到完整结果后一次展示。 |
| PDF 翻译 | BabelDOC 驱动的翻译、单语/双语 PDF、预览与导出、工作列表和后台排队，以及分组高级设置。 | 使用所选文本/PDF 服务配置。首次需要下载运行组件；复杂版式和扫描件有适用限制。 |
| 录音与录后转写 | 麦克风、整台电脑或指定应用声音录制，音频文件导入；转写后可编辑、按可用时间定位回听、保留多个结果并导出。 | 录音保存或导入后，由你主动发起转写。仅提供固定的 OpenAI/AiHubMix 模型预设，每次录音选择一种音源。 |
| 实时双语字幕 | Gemini Live 原文与译文、独立字幕窗、本地录音、历史编辑及缺口处理入口。 | Gemini Live 单独适配，使用独立的服务配置与密钥。应用显示双语文字，不承诺译文语音播报。 |

文本与 PDF 共用提示词预设和术语表，可分别选择默认服务。文本翻译独立于后台任务队列；文件处理任务排队执行。源语言可以在本机自动检测，检测本身不会提交翻译。

## 系统要求与首次使用

- Apple Silicon Mac（M 系列芯片）；当前不提供 Intel 版本。
- 当前最低系统目标为 **macOS 14.2+**，但尚未在 macOS 14.2 实机验证，不能据此理解为所有目标系统和依赖均已通过测试。
- 简体中文、英文界面，可跟随系统或手动切换。
- 云端翻译和识别需要网络，以及对应服务可用的 API Key 和账户额度。

运行应用后，先在设置中添加需要的服务：

1. **文本/PDF：** 配置服务地址、模型和 API Key，选择文本与 PDF 各自的默认配置。文本页统一使用文本默认服务。
2. **录后转写：** 选择 OpenAI 或 AiHubMix 的固定预设，保存该服务的密钥。目前预设为 OpenAI `whisper-1`、`gpt-4o-transcribe-diarize`，以及 AiHubMix `whisper-large-v3`、`whisper-large-v3-turbo`、`whisper-1`。
3. **实时双语字幕：** 单独配置 Gemini Live 的 API Key。文本/PDF 或录后转写的密钥不会自动转用于此服务。
4. **PDF：** 首次使用时由应用自动准备托管运行环境，显示下载进度并支持失败重试；成功后复用。应用已附带部分字体与运行组件，其余锁定输入首次下载约 **359 MB**；安装和解包还需要额外磁盘空间，普通用户无需手动安装 Python。

保存配置本身不会开始录音或发起翻译。录音时根据所选音源授予麦克风或系统音频录制权限；系统声音采集使用 macOS 的屏幕与系统音频录制权限，应用不保留屏幕画面。

## 资料、密钥与费用

原始录音、导入文件的独立副本及保存的结果由应用在本机保管。你可以重新打开历史、编辑、回听和导出；重新处理音频或 PDF 会保留旧结果及其编辑，文本每次明确提交形成独立历史记录。

**本地保存不等于离线处理。** 当你提交翻译/转写任务或开始实时双语字幕时，相关文字或音频会发送给所选云端服务。PDF 翻译会将提取的文字和相关翻译指令交给所选服务处理。密钥保存在 macOS 钥匙串中，并按服务和连接目标隔离。

翻译与识别可能产生服务商费用，由你向相应服务商支付，价格、账户限制和内容留存政策由该服务决定。Gemini 实时模型可能生成计费音频，即使应用只显示双语文字，也不能据此理解为没有音频费用。

## 预览版的能力边界

- 文本/PDF 提供 OpenAI-compatible 配置和 DeepSeek 等预设；兼容协议不代表每个服务、模型和参数组合都已验证。
- 录后转写不提供任意兼容端点或自定义模型入口。AiHubMix 的已有真实使用结果不能代替 OpenAI 官方或所有预设模型的成功验证；段落时间能力也不等于所有语言和模型都达到相同定位精度。
- Gemini Live 与 OpenAI-compatible 接口分别适配。长会话、真实断线恢复及双语文件补齐仍保留各自的验证缺口；文件补齐尚无真实 Gemini 服务成功记录。
- 语言菜单的可选项不等于逐语言翻译质量已验证。当前完整验收重点为简体中文和英文。
- PDF 不保证任意版式、公式或字体无损；纯图片扫描件不会自动获得 OCR 识别。批量 PDF 的完整真实服务流程仍有未完成的验证。
- 普通用户无开发环境的首次安装、PDF 组件首次准备及最新源码对应的候选验证，仍是公开首发前需要完成的工作。Developer ID 签名与 Apple 公证已不作为本次预览版的条件。

这些边界会随实际验证更新，具体首发条件见[发布准备清单](docs/release-preparation.md)。

## 从源码构建

以下命令面向开发者，在仓库根目录执行。需要 Apple Silicon Mac 和 Swift 6 工具链（Xcode 或相应 Command Line Tools）；开发工具要求与普通用户安装要求不同。

调试构建并启动：

```sh
bash app/macos/scripts/build-app.sh debug
open app/macos/.build/app/TranslationWorkbench.app
```

退出该应用后，可以构建并启动 Release 开发包：

```sh
WORKBENCH_SIGNING_IDENTITY=- WORKBENCH_SIGNING_KEYCHAIN='' bash app/macos/scripts/build-app.sh release
open app/macos/.build/app/TranslationWorkbench.app
```

项目品牌已定为 Crosscript，当前内部构建产物仍名为 `TranslationWorkbench.app`。上述命令显式选择 ad-hoc 签名，不使用本地签名身份或钥匙串。计划中的公开预览包同样使用 ad-hoc 签名，不做 Developer ID 签名或公证，本次发行计划无需加入 Apple Developer Program。ad-hoc 签名不验证发行者身份。

Debug 与 Release 测试入口：

```sh
bash app/macos/scripts/test.sh -c debug
bash app/macos/scripts/test.sh -c release
```

原生 AppKit 用例需要独立进程，真实 PDF bridge 集成测试还需要已准备的托管运行时。完整候选回归使用[隔离回归脚本](scripts/dev/run-final-local-regression.py)，其参数包括固定源码提交、独立输出目录及运行时路径；不能将缺少相关前置条件的通用测试运行视为完整发行验收。

## 反馈与贡献

欢迎提交问题反馈和 PR。项目由个人维护，不承诺响应或修复时限。反馈时请说明系统版本、芯片、工作流、所选服务和模型，以及可复现步骤；公开反馈中请勿附带 API Key 或未经处理的私人录音、文档。

自有代码贡献采用 [AGPL-3.0-only](LICENSE)，具体要求见[贡献指南](CONTRIBUTING.md)。第三方内容保留其原有授权。

## 许可证与第三方组件

Crosscript 自有代码采用 **GNU Affero General Public License v3.0 only（AGPL-3.0-only）**，完整条款见 [LICENSE](LICENSE)。允许在遵守许可证的前提下商用、修改和再分发，不额外禁止出售、商业嵌入、收费服务或捐赠。

分发受许可证约束的作品时，须按规定提供对应源码并保留通知；支持远程网络交互的受约束修改版还须按 AGPL 向相应用户提供获取源码的机会。仅本机私人修改使用本身不要求向公众发布修改。

第三方代码、运行时、模型和字体继续适用各自许可，见[第三方通知与范围](THIRD_PARTY_NOTICES.md)及 [PDF 组件通知](app/macos/Sources/TranslationWorkbench/Resources/PDF/Notices/README.md)。本地 build 5 配套材料已收录匹配源码／构建输入、修改通知和当前索引，包括已批准的字体身份更名与 GMP／ZeroMQ／OpenSSL 受控构建。实际对外获取方式、整包人审和另一台普通 Mac 安装仍是独立门槛，见[分发材料说明](docs/distribution-materials.md)。

已确认公开目标为 [yqia03/crosscript](https://github.com/yqia03/crosscript)。本候选采用 build 5，许可、同版源码和完整材料的[版本入口](docs/source-and-build.md)待发布后生效；当前不声称链接已可访问。旧 build 4 的用户声明验收不替代本候选的新增验证。
