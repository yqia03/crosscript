# Crosscript

**Translation Workbench for macOS**

[简体中文](README.zh-CN.md)

A native translation and transcription workbench for Apple Silicon Macs. Bring your own API keys to translate text, Markdown and PDFs, transcribe recordings, and follow live bilingual captions. Keep original materials and editable results on your Mac.

**Pre-release:** The first public release is planned as **0.1.0 preview** under AGPL-3.0-only. No public download is available yet. Source code and a preview app without Developer ID signing or Apple notarization will be published together after source review, third-party distribution preparation and installation checks are complete.

## What you can do

| Workflow | Features |
| --- | --- |
| Text and Markdown | Translate on explicit submission, compare source and translation, edit results, reopen history, and export text or bilingual Markdown. |
| PDF translation | Translate PDFs with BabelDOC, choose monolingual or bilingual output, and adjust common and advanced settings. The app prepares its PDF components on first use. |
| Recording and transcription | Record a microphone or system audio, including audio from a selected app; import audio, transcribe after recording, edit text, replay available timestamps, and export. |
| Live bilingual captions | Follow source text and translation through Gemini Live in the main view or a floating caption window, with a locally saved recording. |

Text and PDF translation share saved prompts and glossaries. Long-running file tasks use a background queue while interactive text translation remains available.

## Platform and download status

- **Hardware:** Apple Silicon Macs.
- **System target:** macOS 14.2 or later. This is the declared deployment target; testing on macOS 14.2 has not been completed.
- **Interface:** English and Simplified Chinese.
- **Services:** Your own API keys and access to the service supported by each workflow.
- **PDF setup:** The app includes selected font/runtime components; first preparation downloads the remaining pinned inputs (about 359 MB) and requires extra installation space. The environment is reused afterward.

The public installer and download instructions will be added when the release checks pass. Ordinary-user installation without development tools is still awaiting verification. The intended packaged app manages its PDF environment without asking users to install Python.

The preview will use ad-hoc signing for integrity checks. It will not have a verified Developer ID or Apple notarization ticket. macOS may block its first launch; the release will include instructions for Apple's per-app **Open Anyway** flow where available. Installation on a separate Mac is still unverified. See [Apple's explanation](https://support.apple.com/en-us/102445).

## Configure and use

Once you have a running app:

1. Open **Settings** and add the service configuration needed for your workflow. Text and PDF translation can have separate defaults.
2. Enter that service's API key and select a supported model or audio preset.
3. Choose the source and target languages, add text or a file, or select an audio source.
4. Submit translation or transcription explicitly, or start a live caption session. You can edit, revisit and export saved results.

Text translation uses the default text service from Settings. The translate button or Enter submits; Shift+Enter inserts a newline. Opening history and editing text do not submit a translation.

### Service support varies by workflow

| Workflow | Connection |
| --- | --- |
| Text / Markdown | A configured OpenAI-compatible text endpoint and model. |
| PDF | A configured text/PDF service through the managed BabelDOC runtime. |
| Recorded-audio transcription | Built-in OpenAI and AiHubMix presets with fixed endpoints; arbitrary audio endpoints and model IDs are not supported. |
| Live bilingual captions | The separately adapted Google Gemini Live protocol and Gemini credentials. |

Compatibility with a text API does not establish compatibility with audio or live translation. Provider availability, model access and verified capabilities vary.

## Your data and API costs

Original recordings, imported file copies and saved results are stored on your Mac until you delete them. API credentials are stored in macOS Keychain.

When you run a translation, transcription or live session, the content needed for that task is sent to the selected service. Local storage does not make cloud processing offline. API usage may incur charges from that provider, including when a result is unsuccessful or incomplete. A live service may bill for generated audio even when the app only displays text. Check the provider's pricing and data policies before sending content.

Microphone and system-audio capture require the relevant macOS permissions. PDF translation prepares its processing environment on first use from bundled components and the remaining pinned downloads.

## Preview limitations

- The initial end-to-end validation scope is English and Simplified Chinese. Additional language choices do not imply that every language has been quality-tested.
- AiHubMix transcription has recorded real-use validation. Successful OpenAI transcription has not been verified; support and timestamp accuracy should be assessed per preset.
- PDF results depend on the document and engine. Complex layouts, scanned pages, formulas and fonts are not guaranteed to survive unchanged. Recent batch validation was only partially completed.
- Gemini Live has short real-service validation, with remaining gaps around long sessions, reconnection and file-based gap repair. Live translation presents bilingual text; translated speech output and fixed latency are not promised.
- Historical tests and acceptance reports apply to their recorded source versions. The latest source still needs release-specific regression and installation evidence.

## Build from source

Development requires an Apple Silicon Mac and a Swift 6 toolchain with the macOS SDK and Swift Testing. Run these commands from the repository root:

```sh
WORKBENCH_SIGNING_IDENTITY=- WORKBENCH_SIGNING_KEYCHAIN='' bash app/macos/scripts/build-app.sh release
open app/macos/.build/app/TranslationWorkbench.app
```

The current build artifact is still named `TranslationWorkbench.app`; the internal package name, bundle identifier and storage paths have not been migrated to the Crosscript brand. Launch the `.app` bundle for audio permission testing.

This command explicitly selects ad-hoc signing without using a local signing identity or keychain. The public preview will also use ad-hoc signing, without Developer ID signing or notarization; joining the Apple Developer Program is not a prerequisite for this release plan. Ad-hoc signing does not verify the publisher's identity.

Run the native test suites with:

```sh
bash app/macos/scripts/test.sh
bash app/macos/scripts/test.sh -c release
```

AppKit test cases need separate processes, and real PDF bridge integration tests require a prepared managed runtime. The [isolated regression driver](scripts/dev/run-final-local-regression.py) takes a fixed source commit, an independent output directory and a runtime path. The commands above are test entry points, not complete release acceptance or a claim that the current candidate has passed. The Python/browser prototype is separate from the native app.

## Feedback and contributions

Crosscript began as a personal tool shared for people with similar needs. Bug reports and pull requests are welcome; maintenance is on a best-effort basis with no guaranteed response time.

The confirmed public destination is [yqia03/crosscript](https://github.com/yqia03/crosscript). The [build 5 source and material links](docs/source-and-build.md) take effect after the matching version is published; they are not verified downloads yet. Contributions to the project's own code follow the [AGPL-3.0-only license](LICENSE) and [contribution guidelines](CONTRIBUTING.md). Reports should include the app version, macOS version, workflow and reproduction steps; remove API keys and private content from logs and samples.

## License

Crosscript's own code is licensed under the **GNU Affero General Public License v3.0 only (AGPL-3.0-only)**; see [LICENSE](LICENSE). Commercial use, modification and redistribution are allowed under that license. Distribution of covered works requires the corresponding source and other applicable notices; modified versions that support remote network interaction must offer the source as required by the AGPL. Private local use does not by itself require publishing modifications.

Third-party code, runtime components, models and fonts retain their respective licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the bundled [PDF component notices](app/macos/Sources/TranslationWorkbench/Resources/PDF/Notices/README.md). The local build 5 companion contains matching source/build materials, modification notices and current indexes, including the approved font identity and GMP/ZeroMQ/OpenSSL builds. Final recipient access, whole-candidate review and ordinary-Mac installation remain separate gates; see [distribution materials](docs/distribution-materials.md).

Maintainer preparation: [release decisions and checklist](docs/release-preparation.md). See [testing scope](docs/testing.md) before running any tests.
