# Workflows and release scope

Crosscript is a native Apple Silicon macOS translation and transcription workbench. The internal executable is currently TranslationWorkbench. Its four workflows are included in the published [0.1.0 build 5 preview](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5). The signed display name remains 翻译工作台; the project/release brand is Crosscript.

| Workflow | Scope | External processing |
| --- | --- | --- |
| Text and Markdown | Explicit submission, source/translation comparison, editable results, history and text/bilingual Markdown export | Selected OpenAI-compatible text provider |
| PDF translation | Managed BabelDOC runtime, selectable output/layout settings, source-preserving import and export | Selected PDF/text provider when translation is requested; explicit local modes are not translated output |
| Recording and post-recording transcription | Microphone or system audio, import, preserved audio, editable transcript and export | Supported recorded-audio provider when transcription is requested |
| Live bilingual captions | Locally saved recording, source/translation text and optional caption window | Adapted Gemini Live protocol with separate credentials |

Local material storage does not imply offline cloud processing. API credentials belong in macOS Keychain. Entering history, editing text and creating an empty recording project must not itself submit a new provider request. Service and model compatibility are scoped by workflow; text API compatibility is not proof of audio/live support.

Shared terminology is in [CONTEXT.md](../CONTEXT.md). Platform limits, provider limitations and data/cost information remain in the [README](../README.md). Use the [current user guide](getting-started.md) / [中文说明](getting-started.zh-CN.md) for installation, history and export. Build 5 second-Mac checks were not run and were explicitly waived on 2026-10-30. Old development checks do not establish final installation or provider acceptance; see [user-material verification](release-verification/build5/user-materials.md).
