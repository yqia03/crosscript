# Install and use Crosscript build 7

[简体中文](getting-started.zh-CN.md) · [Project overview](../README.md) · [Release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.7)

This guide describes the released Apple Silicon preview **0.1.0 (7)**. The matching Release provides the DMG, App ZIP and optional complete materials; see [build verification](release-verification/build7/README.md) for the actual checks. The App bundle is `Crosscript.app`, with display and executable name **Crosscript** and bundle ID `dev.uown.translation-workbench`.

## Upgrade from TranslationWorkbench.app

The bundle ID, existing material paths, preference domain and Keychain service names remain unchanged for compatibility; renaming the App does not require moving or deleting those stores. Older releases used `TranslationWorkbench.app`.

Before installing build 7, stop and save recordings, finish or cancel processing, quit every old copy and back up needed materials. Remove only the old `TranslationWorkbench.app` from Applications, then install `Crosscript.app` and open that exact installed path. Do not remove the data directories or Keychain items listed below. The different filenames do not trigger Finder's usual replacement prompt; avoid keeping or running both copies, since they share storage and preferences. macOS may request microphone or screen/system-audio permission again; permission inheritance has not been verified. Keep the existing macOS security settings and follow the applicable per-app opening flow.

## Download, check and open

1. Choose **[DMG (recommended)](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.7/Crosscript-preview-0.1.0-7.dmg)** or **[App ZIP](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.7/Crosscript-preview-0.1.0-7.zip)**. You only need one. To check the download in Terminal, run the corresponding command and compare its SHA-256 with the matching Release body:

   ```sh
   shasum -a 256 Crosscript-preview-0.1.0-7.dmg
   # For the ZIP instead:
   shasum -a 256 Crosscript-preview-0.1.0-7.zip
   ```

2. Quit any older copy and back up needed materials. For the DMG, open it, drag `Crosscript.app` to Applications, eject the disk image, then open the installed app. For the ZIP, extract it in Finder, move `Crosscript.app` to Applications, then open it. The target is macOS 14.2+ on Apple Silicon; macOS 14.2 itself has not been physically tested. No developer tools are required.
3. This preview uses **ad-hoc integrity signing**, without Developer ID authentication or Apple notarization. If macOS blocks it, consult [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). Use the system's applicable per-app flow without disabling global protection, removing quarantine or re-signing. Stop on a mismatched checksum/signature or malware/damaged-app warning and retain the exact message for a sanitized report.
4. Open Settings to select English or Simplified Chinese and configure your services. Installing the app does not provide service accounts, API credit or keys.

The optional [complete materials archive](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.7/Crosscript-materials-0.1.0-7.tar.gz) contains the exact source archive, third-party source/build materials, notices and evidence. It is not needed to install or run the app. Use the Release body for its checksum and the archive's index for its contents.

**Validation scope:** build 7 records 62 passing tests, native Finder layout/remount and ZIP/DMG consistency checks, plus Finder Copy/Paste installation and isolated launch on the build Mac, followed by cleanup. A later [actual Finder drag check](release-verification/build7/drag-install.json) also passed: the installed copy matched the full App tree and strict signature, launched with isolated synthetic legacy data, quit normally and was cleaned up; the old App remained unchanged. Ordinary-Mac installation, Gatekeeper, real Keychain/TCC migration, minimum-OS compatibility and cloud workflows remain unverified. Historical build 5 second-Mac B01–B06 were not run and were waived on 2026-10-30; that waiver and older checks do not establish build 7 installation, permissions or cold-download acceptance. The [frozen build 5 installation/removal reference](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/INSTALL-UNINSTALL-LIMITATIONS.zh-CN.md) remains historical; its data and Keychain paths are retained below.

## Configure services and understand data flow

Add your own service configuration in Settings. Text and PDF may have separate defaults and share prompts/glossaries. Credentials are stored in macOS Keychain, separated by service and target. Leaving an existing credential field empty when saving retains the saved key; use the appropriate remove-key control to remove it.

| Workflow | Configure | Content and charges |
| --- | --- | --- |
| Text / Markdown | OpenAI-compatible endpoint, model and key; choose the text default | Source text and translation instructions go to that endpoint on explicit submission. Local source-language detection does not itself translate. |
| PDF | Selected PDF/text profile; managed BabelDOC components | Extracted text and translation instructions go to the selected provider when translating. Local environment setup is separate from provider processing. |
| Post-recording transcription | Fixed OpenAI or AiHubMix preset and that service's key | Audio is sent when you explicitly request transcription; an imported copy/recording is retained locally. Arbitrary audio endpoints/models are not offered. |
| Live bilingual captions | Separate Gemini Live key/configuration | Audio is sent during the live session; a local recording and bilingual text are retained. Text-compatible keys/endpoints do not imply Gemini support. |

Provider calls, connection checks, retries and unsuccessful/incomplete results can incur charges. A live model may generate billable audio even though only text is shown. Prices, account/model access, retention and usage limits come from your selected provider. No service price or universal compatibility guarantee is included. Review the provider's policies before submitting sensitive content.

Microphone or system-audio capture requests the relevant macOS permission when needed. Choose one source per recording: microphone (default or selected input), whole-system audio or a selected app. Screen/system-audio permission is used for audio capture; screen images are not retained by the app.

## Prepare PDF components

The app manages runtime `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`, including Python 3.12.15. No separate Python, Homebrew, Xcode or compiler is required for ordinary packaged-app use.

The manifest has 267 pinned inputs: 22 bundled inputs (20 renamed fonts and two modified wheels) and **245 HTTPS downloads totaling 359,471,768 bytes**. This is the remaining payload, not the total disk footprint; reserve space for extraction, installation, temporary work and PDFs. The app shows preparation progress, checks the bytes and reuses the prepared environment. On failure, retain the error and use normal retry. Do not transplant another machine's cache, replace managed libraries or edit the inventory to bypass checks. Offline installation from fixed local inputs was checked historically; real cold downloads on another Mac were not.

## Work, revisit and export

| Workflow | Start / revisit | Save or export |
| --- | --- | --- |
| Text / Markdown | Enter source, choose direction and format, then Translate or Enter; Shift+Enter inserts a newline. Each submission creates a history entry. Opening an entry restores the workspace without a new provider request. | Edit the translation; export source, TXT or Markdown from the action menus. Bilingual Markdown requires the result to match the current source/direction/format; changed input may require another explicit translation. Existing history entries are not rewritten by workspace edits. |
| PDF | Import a PDF, select options and explicitly request translation. Reopen saved material from history. Removing an item from the workspace list does not delete history or cancel a task. | Preview and export the available monolingual/bilingual output. Reprocessing keeps earlier results. Scanned-image OCR and lossless complex layout/formula/font preservation are not guaranteed. |
| Recording | New Project creates an empty workspace; it does not record, upload or request permission. Start recording or import audio, then request post-recording transcription. Reopen history, choose a result and replay available timestamps. | Edit/copy/export the selected transcript through its controls. Retranscription preserves earlier results and edits. Keep the original audio and your exports if you need an independent backup. |
| Live captions | Configure Gemini, select the audio source and start explicitly. Use the main view or floating captions; revisit saved recording/bilingual history afterward. | Edit, copy or export bilingual text as TXT. A missing text interval is not proof that local audio was lost; gap repair is explicit and has its own provider/verification limits. |

File processing tasks queue with at most one background task running; interactive text translation is independent. A new provider request may cost money. Opening history, editing text and local save/export do not by themselves submit a new translation.

## Known limits and support

The [overview's workflow evidence table](../README.md#data-costs-and-verification-limits) distinguishes historical validation from current gaps. In particular, official OpenAI transcription success is not verified; AiHubMix evidence does not cover every preset. Gemini long sessions, real reconnection and real file-based gap repair remain gaps. The previously stopped PDF batch and real/paid probes remain stopped. Build 7 packaging does not establish new live/provider acceptance.

For help or a bug, use [GitHub Issues](https://github.com/yqia03/crosscript/issues/new) with app/build, macOS, chip, workflow, provider/model, reproduction steps and the exact sanitized error. Remove keys, private documents/audio and machine-specific paths. Use the [private vulnerability report](https://github.com/yqia03/crosscript/security/advisories/new) for security-sensitive findings; see [SECURITY.md](../SECURITY.md). This is a personally maintained preview with no promised response time.

## Remove the app or local data

Stop and save work, finish/cancel tasks, quit the app and back up needed materials. Removing the app bundle (`Crosscript.app` in build 7; older releases used `TranslationWorkbench.app`) leaves data, preferences and Keychain credentials for reinstallation; it does not revoke a provider key.

The default material root is `~/Library/Application Support/TranslationWorkbench/Recordings/`, unless a custom `--data-directory` was used. It contains recordings, `TextWorkspace/` (possibly older `TextMaterials/`), `PDFMaterials/`, configurations and `PDFRuntime/`. If you only want to clear PDF components, identify `PDFRuntime/` separately; do not delete the whole recordings root accidentally. Application preferences use `dev.uown.translation-workbench`.

Prefer the app's targeted remove-key controls. The Keychain services are `TranslationWorkbench.TextPDFProviders` and `TranslationWorkbench.OpenAIAudio` (the latter also includes Gemini credentials). Removing local credentials does not revoke them remotely. External originals, exports, backups and provider retention are separate. No uninstall, deletion, secure-erasure or zero-residue test is claimed. See the linked historical build 5 installation reference for the detailed path/account scope.
