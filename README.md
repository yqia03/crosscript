# Crosscript

**Translation and transcription for macOS** · [简体中文](README.zh-CN.md)

A native translation and transcription workbench for Apple Silicon Macs. Bring your own API keys to translate text, Markdown and PDFs, transcribe recordings, and follow live bilingual captions. Original materials and editable results stay on your Mac; cloud processing sends the content needed for a task to your selected service.

**Released preview: [0.1.0 build 7 / v0.1.0-preview.7](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.7).** The Release provides three downloads; [build 7 verification](docs/release-verification/build7/README.md) records the source and package checks. This preview uses ad-hoc integrity signing without Developer ID publisher authentication or Apple notarization.

## Download and install

Choose one app download from the matching Release:

- **[DMG — recommended](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.7/Crosscript-preview-0.1.0-7.dmg):** open it, drag `Crosscript.app` to Applications, eject the disk image, then open the installed app.
- **[App ZIP](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.7/Crosscript-preview-0.1.0-7.zip):** extract in Finder, move the app to Applications, then open it.
- **[Complete materials archive](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.7/Crosscript-materials-0.1.0-7.tar.gz):** optional for ordinary use; contains the exact source archive, third-party source/build materials, notices and release evidence.

Use the Release's SHA-256 values to check your download. The [installation and use guide](docs/getting-started.md) covers first open, services, history, exports and removal.

- **Hardware:** Apple Silicon (arm64); no Intel build is provided.
- **System target:** macOS 14.2 or later. That exact minimum OS has not been physically tested.
- **Interface:** English and Simplified Chinese.
- **App name:** build 7 uses `Crosscript.app`, with display and executable name **Crosscript**. Existing data paths, preferences and Keychain services retain their compatible identifiers. Quit the old app and remove only its `TranslationWorkbench.app` bundle before installing; preserve data and credentials. See the [upgrade guidance](docs/getting-started.md#upgrade-from-translationworkbenchapp).
- **First open:** macOS may block this non-notarized app; see the guide's per-app opening instructions.
- **PDF preparation:** 22 inputs are bundled; 245 remaining pinned HTTPS inputs total 359,471,768 bytes (about 359 MB). Extra installation and processing space is required. The app manages Python; users do not need Homebrew, Xcode or a separate Python installation.

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
| Whole app / installation | Build 7 records 62 passing tests, native Finder layout/remount and ZIP/DMG consistency checks, plus Finder Copy/Paste installation and isolated launch on the build Mac, with cleanup. A later [actual Finder drag check](docs/release-verification/build7/drag-install.json) also passed: the installed copy matched the full App tree and strict signature, launched with isolated synthetic legacy data, quit normally and was cleaned up; the old App remained unchanged. Ordinary-Mac, Gatekeeper, real Keychain/TCC migration, macOS 14.2 hardware and cloud-workflow acceptance remain unverified. Historical build 5 second-Mac B01–B06 were not run and were waived on 2026-10-30; that waiver applies only to build 5. |

Language choices are not a per-language quality guarantee; the initial validation focus is English and Simplified Chinese. Stopped PDF batches and live/paid service probes have not resumed. See the [historical build 5 evidence index](docs/release-verification/build5/README.md), [public delivery and all continuing gaps](docs/release-verification/build5/public-delivery.md), [bounded gaps](docs/release-verification/build5/gaps.md) and [user-material scope](docs/release-verification/build5/user-materials.md).

## Source, contributions and support

- [Report a bug / ask for help](https://github.com/yqia03/crosscript/issues/new): include app/build, macOS, chip, workflow, service/model and sanitized reproduction steps. See [CONTRIBUTING.md](CONTRIBUTING.md).
- [Report a vulnerability privately](https://github.com/yqia03/crosscript/security/advisories/new): see [SECURITY.md](SECURITY.md); do not post credentials or exploitable security details in public issues.
- The [complete build 7 materials archive](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.7/Crosscript-materials-0.1.0-7.tar.gz) provides the exact source, third-party source/build materials and evidence. GitHub's automatically generated source ZIP does not replace the App-bound source archive inside it.

The project is personally maintained with no guaranteed response time. Development requires Apple Silicon, Swift 6 and the macOS SDK. See [source/build instructions](docs/source-and-build.md) and [testing scope](docs/testing.md) before running tests or provider checks. The frozen [build 5 Release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5), tag, App and 28 assets remain available unchanged. Its later approval and waiver apply only to build 5.

## License

Own code is **AGPL-3.0-only**; see [LICENSE](LICENSE) and [contribution terms](CONTRIBUTING.md). Commercial use, modification and redistribution are permitted under the license, including applicable corresponding-source and network-interaction requirements. Third-party components retain their own terms: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [PDF notices](app/macos/Sources/TranslationWorkbench/Resources/PDF/Notices/README.md) and [distribution materials](docs/distribution-materials.md). Source/material availability is distinct from proof of every original build or an all-stack legal conclusion.
