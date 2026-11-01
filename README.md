# Crosscript

**Translation Workbench for macOS** · [简体中文](README.zh-CN.md)

A native translation and transcription workbench for Apple Silicon Macs. Bring your own API keys to translate text, Markdown and PDFs, transcribe recordings, and follow live bilingual captions. Original materials and editable results stay on your Mac; cloud processing sends the content needed for a task to your selected service.

**Released preview: [0.1.0 build 5 / v0.1.0-preview.5](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5).** This is an ad-hoc signed, non-notarized preview without Developer ID publisher authentication. Build 5 second-Mac checks B01–B06 were **not run**; the maintainer waived that gate and approved publication on 2026-10-30. A waiver is not a passing installation test.

## Download and install

Download [Crosscript-preview-0.1.0-5.zip](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-preview-0.1.0-5.zip) from the matching Release. The same Release provides the exact source archive, third-party source/build materials and checksums. See the [installation and use guide](docs/getting-started.md) for integrity checks, first-open limits, setup, history, exports and removal.

- **Hardware:** Apple Silicon (arm64); no Intel build is provided.
- **System target:** macOS 14.2 or later. That exact minimum OS has not been physically tested.
- **Interface:** English and Simplified Chinese.
- **App name:** the downloaded bundle is `TranslationWorkbench.app`; the signed display name is **翻译工作台**. Crosscript is the project/release brand; internal names and data paths remain TranslationWorkbench.
- **First open:** unzip in Finder, move the app to your chosen Applications directory and open normally. macOS may block this non-notarized app. Follow the applicable per-app system flow described in the guide; stop on integrity, malware or damaged-app warnings.
- **PDF preparation:** 22 inputs are bundled; 245 remaining pinned HTTPS inputs total 359,471,768 bytes (about 359 MB). Extra unpacking, installation and processing space is required. The app manages Python; users do not need Homebrew, Xcode or a separate Python installation.

## Four workflows

| Workflow | Use and saved results | Service boundary |
| --- | --- | --- |
| Text / Markdown | Explicit submission, source/translation comparison, editable results, independent history, TXT / Markdown / bilingual Markdown export | Configured OpenAI-compatible text endpoint and model |
| PDF translation | Managed BabelDOC runtime, monolingual/bilingual PDF, preview, history and export; shared prompts and glossaries | Selected PDF/text provider |
| Recording and post-recording transcription | Microphone or system audio (including a selected app), audio import, editable transcript, playback and export; one source per recording | Fixed OpenAI / AiHubMix presets; no arbitrary audio endpoint or model |
| Live bilingual captions | Gemini Live source/translation text, optional floating captions, saved recording and editable bilingual history | Separately adapted Gemini Live protocol and credentials |

Open Settings and configure the required service and your own key. Text and PDF can use different defaults. Text translation uses the default text service: Translate or Enter submits, Shift+Enter adds a newline. Opening history, editing text and saving settings do not themselves submit translation. File tasks share a background queue; interactive text translation remains available.

## Data, costs and verification limits

Credentials are stored in macOS Keychain. Original recordings, imported copies and results are saved locally until you delete them. Explicit translation, transcription, a connection check or a live session may send content to a service and incur provider charges, including unsuccessful or incomplete work. Local storage does not mean offline processing. Gemini may generate billable audio even though the app displays text. Check the selected provider's pricing, retention and account limits before sending content.

| Workflow / platform | Evidence and remaining limits |
| --- | --- |
| Text / Markdown | Existing implementation and scoped historical checks; an OpenAI-compatible label does not verify every provider, model, parameter or language. No fresh cloud-provider acceptance in this verification. |
| PDF | Focused offline runtime installation/reuse and component checks are recorded; they do not prove cold downloads on another Mac or arbitrary document quality. The earlier partial PDF batch remains stopped. Scanned images do not automatically gain OCR; layout, formulas and fonts may change. |
| Recorded audio | AiHubMix has historical real-use validation; successful official OpenAI transcription and every preset's timestamp accuracy are not established. |
| Gemini Live | Short historical real-service validation; long sessions, real reconnection and file-based gap repair retain gaps. No real Gemini file-repair success is claimed. Translated speech and fixed latency are not promised. |
| Whole app / installation | License-component tests and packaging checks are scoped evidence. Build 5 second-Mac B01–B06 were not run and were waived; build 4 acceptance is not inherited. macOS 14.2 hardware testing and full workflow acceptance remain unverified. |

Language choices are not a per-language quality guarantee; the initial validation focus is English and Simplified Chinese. Stopped PDF batches and live/paid service probes have not resumed. See [current build 5 evidence and user-material scope](docs/release-verification/build5/user-materials.md).

## Source, contributions and support

- [Report a bug / ask for help](https://github.com/yqia03/crosscript/issues/new): include app/build, macOS, chip, workflow, service/model and sanitized reproduction steps. See [CONTRIBUTING.md](CONTRIBUTING.md).
- [Report a vulnerability privately](https://github.com/yqia03/crosscript/security/advisories/new): see [SECURITY.md](SECURITY.md); do not post credentials or exploitable security details in public issues.
- [Exact build 5 source](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-source-0.1.0-5.tar.gz) and [third-party materials](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz) accompany the preview. GitHub's automatically generated source ZIP is not the App-bound source archive.

The project is personally maintained with no guaranteed response time. Development requires Apple Silicon, Swift 6 and the macOS SDK. See [source/build instructions](docs/source-and-build.md) and [testing scope](docs/testing.md) before running tests or provider checks. Current documentation updates do not rebuild or alter the frozen build 5 tag, App or 28 release assets. Historical publication-pending wording in those objects is explained by the Release's later approval and waiver.

## License

Own code is **AGPL-3.0-only**; see [LICENSE](LICENSE) and [contribution terms](CONTRIBUTING.md). Commercial use, modification and redistribution are permitted under the license, including applicable corresponding-source and network-interaction requirements. Third-party components retain their own terms: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [PDF notices](app/macos/Sources/TranslationWorkbench/Resources/PDF/Notices/README.md) and [distribution materials](docs/distribution-materials.md). Source/material availability is distinct from proof of every original build or an all-stack legal conclusion.
