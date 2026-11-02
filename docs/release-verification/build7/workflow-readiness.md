# Build 7 workflow readiness: historical reuse and candidate differences

Prepared 2026-11-02 for [translation #16](https://github.com/yqia03/crosscript/issues/16) and [recording/transcription #17](https://github.com/yqia03/crosscript/issues/17), under [support/evidence matrix #15](https://github.com/yqia03/crosscript/issues/15). **This is a source/evidence preflight, not executed workflow acceptance.** Do not close #16/#17 or begin their formal acceptance until #15 fixes their exact service/model/language scope and dependencies. The reviewed build input is `4579cac20caafdd4dc716def209cb21b8b100a66`; later packaging/evidence commits do not silently replace it. See the [candidate identity and existing results](README.md).

No new tests, application launch, capture, GUI operation, network service, cloud request, download or Keychain operation were performed for this preflight. Historical descriptions were inspected without opening user audio or PDF bodies. Private evidence, paths, credentials, account identifiers and original personal samples remain outside the public deliverable.

## Reuse rule

A historical real request may establish its selected provider/protocol and observed content; it does not automatically establish a changed input contract or current App behavior. Reuse requires an identifiable historical sample/run, exact requested provider/model and language, attributable outcome, and a source comparison explaining the affected boundary. Local controlled tests establish candidate behavior at their injected boundary, never a new real-service success. Retain historical failures, omitted cases and user waivers independently.

The comparison used preserved development revisions for the 2026-10-15 T29 matrix, T7 transcription version acceptance, and the 2026-10-20 real-service window. Only the conclusions and current source identities are published here; original development history and sample materials are not copied into the public repository.

## Text and Markdown

| Boundary | Historical evidence that can be reused | Candidate difference and exact remaining condition |
| --- | --- | --- |
| DeepSeek official target / `deepseek-flash`, both language directions, streaming and non-streaming completion | T29 recorded eight real requests: English→Chinese/Chinese→English × plain/Markdown × stream/JSON. Each had programmatic edit/export/reopen checks. The later 2026-10-20 window recorded four additional successful streaming text requests. | These are evidence of their exact adapter/session revisions. The production default is now non-streaming. Do not claim the current App still has a streaming selection merely because its adapter retains a streaming mode. |
| Plain text without a line break | The old non-streaming completion used the same ordinary translation contract, with reasoning separate from visible text. | Current `PlainTextTranslationLayout.init` returns nil for input without a newline, so old real JSON completion remains relevant. Selected-language routing, explicit submit, history and pane behavior require candidate local checks. |
| **Plain text with a line break** | Old plain samples were single-line, and the later four-request window used streaming. | On 2026-10-21 the default changed from `.streaming` to `.nonStreaming`. For multiline plain input, `OpenAITextTranslator` now sends JSON Lines with integer line IDs, requires one nonempty translated line per ID, and reconstructs original blank lines/separators. **No inspected historical real run establishes the selected model satisfying this new contract.** Controlled HTTP tests cover its implementation, not real model compliance. This is a specific real-service gap; it cannot be marked closed by the old eight-way matrix. |
| Markdown request and retained structure | T29 real samples covered nested lists, duplicate code with different fences, comments, formulas, links and image paths; local edit/export/reopen was recorded. Current parsing/request/bilingual machinery retains that source-owned contract. | Compared with T29, `MarkdownDocument` adds direct editor projection of a single editable span, rejecting protected syntax/cross-span changes. Compared with the 2026-10-20 window, this file is byte-identical. Default non-streaming delivery is covered by the old Markdown JSON completion evidence, but candidate edit/history behavior needs local checks. |
| Markdown tables | Current complex/escaped-pipe tests include table skeleton, cell leaves, inline code and protected formulas. | Do not assert that T29's real sample contained a table: its inspected source did not. Table syntax preservation has local source-owned evidence; it is not a separate real model/table-quality result. Retain that distinction when completing #16. |
| Current workspace, explicit submit, independent history | Older real results may still be reopened and inspected. | T29's original material/result lifecycle was replaced by a single current workspace with independent per-submit history. Button/Enter, Shift+Enter/IME, restoring/importing/editing without requests, and preserving old history are candidate local/native conditions; old real calls alone do not cover them. Build 7 already has a separately recorded synthetic legacy-upgrade smoke, whose scope remains limited. |

A genuinely minimal later real supplement for the new contract is **one short multiline plain sample per required direction**, each one explicit request, containing a blank line and a repeated sentence with distinct line IDs. A maximum of two is a proposed scope, not authorization. It should reuse the existing adapter/session, record the exact transmitted contract and retained line structure, and require model output to pass the real parser. Do not repeat the entire eight-way matrix, change services, or fabricate missing IDs locally. Any output-token/budget limit must be enforced or honestly described before approval; the production App's ordinary initializer does not itself set `maxOutputTokens`.

## PDF: provider evidence is distinct from the current runtime

Historical short DeepSeek English→Chinese results and the separately recorded one-page Chinese→English result can establish that selected model's observed response in those runs. The Chinese→English page reflowed body paragraphs and reduced/wrapped its title; it was not a claim of original font size or line-for-line layout. The 2026-10-20 PDF-A produced mono/dual output, but that batch's second PDF timed out and the user stopped it. PDF-A success is not final batch export/reopen success, and the stopped batch must not be resumed by this plan.

Concrete source/runtime differences were checked:

- Against the 2026-10-20 successful PDF-A source, `BabelDOCPDFTranslator` adds explicit `sourceLanguage`/`targetLanguage`; the bridge adds normalized language/alias routing and glossary-language filtering. English/Chinese still map to the same `en`/`zh` engine codes. The actual bounded HTTP transport, retry policy and translator request implementation are unchanged in that comparison. `babeldoc_compat.py` is byte-identical.
- Compared with the older 2026-10-15 baseline, the runner also has richer content/layout/performance settings, local-only modes, diagnostics and `PYTHONDONTWRITEBYTECODE`. The later 2026-10-20 PDF-A is the closer evidence for these existing features; do not require a new paid run merely because the earlier source was older.
- The 2026-10-20 runtime was `babeldoc-0.6.4-py312-20261013-arm64-v1`; the candidate selects `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`. The interpreter selection is identical; **two wheel selections differ**: the BabelDOC font derivative and modified OpenCV. Twenty old font paths are replaced by twenty Crosscript font paths. This is a selection comparison, not a newly executed runtime test.
- The BabelDOC derivative changes its font identity/cache registry; original/font-derived pairs have retained bounded rendering, glyph/layout and missing/corrupt-cache checks. The OpenCV derivative replaces selected GMP/ZeroMQ and same-version OpenSSL libraries. Retained ABI/default-algorithm/in-memory TLS checks do not establish a new real HTTPS request or ordinary-Mac installation. OpenCV's changed libraries must not be casually described as a change to the unchanged CPython interpreter's own TLS implementation.
- Build 7's packaged PDF resources/pins match build 6; the retained build 5 component/font/runtime evidence therefore remains relevant to exactly those bytes. Its real preparation used verified cached HTTPS artifacts under network denial; it **does not** satisfy a true HTTPS cold preparation. That separate requirement belongs to #19.

Use the [selected Python/engine record](../build5/python-engine.md), [font/assets record](../build5/assets.md), [current limitations](../build5/gaps.md), and build 7 identity record to join those facts. Current source plus retained focused runtime evidence can support a reasoned reuse decision; it cannot be summarized as “old real PDF passed on the current runtime.” The minimal candidate gap is local engine/render/output and language-routing compatibility for the selected short sample scope, followed by #19's approved HTTPS cold setup. Only an actual incompatible behavior or missing provider-boundary evidence justifies proposing a fresh bounded real PDF request. Existing original/translated output metadata and attribution must be assessed for the actual selected outputs; source inspection is not universal output-notice acceptance.

## Recording and post-recording transcription

The T7 accepted range recorded two real AiHubMix `whisper-large-v3-turbo` English samples of 60 seconds each, plus independent versions, retained old edits, reopen and audio integrity. That does not prove Turbo Chinese, long-file or cross-chunk recognition. Separately, retained Large V3 evidence identifies `https://aihubmix.com/v1` / `whisper-large-v3`, a 5,840.2829-second file and ten sequential HTTP 200 responses, followed by isolated App persistence/reopen checks. Reuse the exact model/language/sample identity; do not convert the 7,293-second **recording** acceptance into a particular model's transcription success or relabel Large V3 evidence as Turbo.

Current `OpenAIFileTranscriber.swift` and `ImportedAudio.swift` are **byte-identical to the T7 source**. The latter owns independent copies and native conversion/chunking; the former retains the same multipart endpoint, request format, decoding and provider error boundary. Adding Gemini to `AudioServiceConfiguration` does not change the inspected AiHubMix model/default/endpoint branches.

The App-level owner did change substantially after T7: async explicit authorization and immutable target snapshots, a durable shared background queue, manual restart/resume, stable attempt IDs, late-result guards, local-save-only retry, and separate transcription/live workflow selection. `RecordingStore` gained workflow migration and queue/repair journals; `TranscriptDocument` gained anchorless newline paragraph splitting. Those changes need local regression of version/edit/data ownership and history navigation. They do not themselves require another successful upload through an unchanged file adapter.

The required import condition is stronger than “the original remained present”: select/copy a synthetic file, remove/move its external original, restart, then read/transcribe/export from the managed copy. Existing tests exercise this directly. Re-transcription tests must keep the earlier edited version and new result independently, including save failure and late callbacks. Empty projects and history opens must not read a key or upload.

If #15 retains Chinese transcription as required and cannot identify a selected model's real Chinese evidence, it remains a real-service gap. A small newly approved Chinese synthetic sample can address that specific gap; neither an English real result nor a controlled Chinese response closes it. Do not narrow the required language scope or re-run a long file without an explicit decision. No new audio request is authorized by this document.

## Minimal existing checks for the parent to schedule

All commands below are **prepared, not executed**. Run from the exact checked source after #15 scope/dependencies are fixed; use fresh scratch/output directories and the existing network-denied test isolation. `test.sh` handles the Swift Testing macro path. Start with Release for the shipped configuration; repeat Debug only when a related fix, configuration-specific concern or project-required checkpoint warrants it. Save command, source/hash, selected test inventory, result and skips. A zero-test match or a runtime skip is not a pass.

1. Text contract, history and protected Markdown (fake credentials/injected transport):

   ```sh
   bash app/macos/scripts/test.sh -c release --filter 'TextTranslationHTTPTests|TextTranslationTests|TextWorkspaceMigrationTests|MarkdownDocumentTests|MarkdownSessionTests'
   ```

   Direct reasons: `multilineTranslationPreservesSourceLinesInWorkspaceHistoryAndExport`, `invalidLineCorrespondenceNeverPublishesOrRetries`, `blankLinesWhitespaceAndUnicodeSeparatorsSurviveTranslation`; `repeatedExplicitSubmissionsAppendHistoryAndRestoringNeverMutatesIt`, `editingImportingRestoringAndChangingSettingsNeverSubmits`; Markdown complex table/escaped pipes/repeated code and `directEditorProjectsTextEditsButRejectsProtectedSyntaxAndCrossPassageChanges`.

2. Selected PDF language mapping and process boundary, with the already available runtime only:

   ```sh
   python3 -B scripts/pdf/test_language_options.py
   bash app/macos/scripts/test.sh -c release --filter 'PDFBridgeProcessTests|PDFTranslationTests'
   ```

   These cover language mapping, source/provider snapshot, subprocess exit/cancel and immutable source/output behavior. `pythonImportsLeaveBridgeResourcesUnchanged` is explicitly conditional on `WORKBENCH_PDF_RUNTIME`; retain that skip when absent. Never point this variable to a new download or substitute development Python to make an absent runtime look installed.

   If current engine/render compatibility lacks a reusable exact-byte result, the existing `scripts/pdf/test_bridge.py` is the small integration entry point: launch using the **already verified candidate runtime's** Python, set `PDF_TEST_CACHE` to its selected assets and `PDF_TEST_OUTPUT` to a fresh isolated location. It starts controlled loopback HTTP, uses the public synthetic one-page fixture, limits requests and tests a successful Chinese output plus failure/cancellation. It is not an Internet-service test. Do not run `test_acceptance_samples.py`'s 24-page matrix or all content/layout matrices merely to refresh their date. Inspect the one resulting output's rendering and metadata under an explicitly permitted local inspection phase.

3. Imported copy, independent versions and queue/restart differences:

   ```sh
   bash app/macos/scripts/test.sh -c release --filter 'AudioImportTests|TranscriptVersionTests|AudioQueueTests/restartRetainsQueueButOnlyAnExplicitResumeStartsWork|AudioQueueTests/receivedResultStaysEditableDuringSaveFailureAndLocalSaveDoesNotResubmit|AudioQueueTests/cancellingQueuedOrRunningWorkRejectsLateResultsAndPreservesNextTask|PostRecordingIntegrationTests/savedRecordingCanBeTranscribedAfterCaptureEnds|PostRecordingIntegrationTests/longImportedAudioUsesSelectedServiceAndPreservesEveryFrame|PostRecordingIntegrationTests/importedSymbolicLinkBecomesIndependentPlayableAudio'
   ```

   The native integration cases generate their own WAV/CAF, inject `URLProtocol` and fake credentials, and use a fixture recorder. The 800-second fixture is generated locally; it does not record for that duration or prove long real-service accuracy. The symlink case loads the managed audio after source removal, without actual playback or microphone capture.

   **Do not run the whole `PostRecordingIntegrationTests` suite in a no-Keychain phase.** `legacyKeychainItemStaysOfficialAndOtherTargetsRemainIsolated`, `asynchronousKeychainReadsPreserveTargetIsolationAndRespectCancellation`, and `systemKeychainConfigurationCanBeReopenedAndRemoved` intentionally access disposable system Keychain items. They are excluded from the command above.

4. Native interaction differences, only in the existing isolated AppKit phase:

   ```sh
   bash app/macos/scripts/test.sh -c release --filter 'TextWorkspaceEditorTests'
   bash app/macos/scripts/test.sh -c release --filter 'RecordingHistoryTests/historyContainsRecordedAndImportedTranscriptionsAndLeavesActiveCaptureUntouched|RecordingHistoryTests/openingHistoryRetainsPendingEditsAndResultSelectionWithoutUploading'
   bash app/macos/scripts/test.sh -c release --filter 'PDFReadingTests/nativeReaderLoadsPagesNavigatesAndSwitchesWithoutChangingFile'
   ```

   Enter/Shift+Enter/IME/clipboard require real AppKit test isolation. As with the existing regression driver, run AppKit cases in separate processes when needed; do not merge them into an arbitrary parallel batch. These tests exercise native controls with synthetic content, not a real App/cloud round trip. Any remaining manual App workflow observation must use isolated synthetic data and retain that classification.

The relevant existing top-level runner is `scripts/dev/run-final-local-regression.py` (with `test-final-regression-driver.py`), not a new architecture. The focused checks above should precede any broader checkpoint. No run is scheduled merely by listing it here.

## Current source fingerprints

These SHA-256 values were read from candidate source during preflight; they are not test results or an additional binary binding.

| Source | SHA-256 |
| --- | --- |
| `OpenAIFileTranscriber.swift` | `5f2a1ff114e98d28a3893c8e4a61d6577fa0845bdd2ed35fe32a2b9979eb13e4` |
| `ImportedAudio.swift` | `84d11fa584eecf874876f8819566e5fa013b143cf0a98d4bbea1bfe1e797bf36` |
| `OpenAITextTranslator.swift` | `4a0596596e95fc4109d5eeadcc0163c27c2749fc4200e9cafad9386bca147ecf` |
| `PlainTextTranslationLayout.swift` | `90f26920a7d187b967fe0fb84ad4b53d1a3a98b3180fe01426757e1d030de267` |
| `MarkdownDocument.swift` | `012c1041f603e02665d1b3c5acbb85ae7c0076242df1ef83bcb30be6f6ff4cf9` |
| `BabelDOCPDFTranslator.swift` | `cdeb0f5b7e868036635fe52f91fd6ddf20bdf9e69ed9029615ece2080887be93` |
| `babeldoc_bridge.py` | `4fbc193b32dba2482854def34110c54e0db0e550c62cc0d381881b874a60fb33` |
| `babeldoc_compat.py` | `f0cec884bd3c28eb41bfddac3b175c6265d587494b92107d5879e60a5673de61` |

Before making a final reuse/acceptance decision, join the selected historical raw evidence to the support matrix, add actual candidate-local results, and separately resolve the new multiline plain contract, any still-required Chinese transcription evidence, final installation/cold setup, and Gemini real boundaries. This preflight neither declares those conditions passed nor weakens them.
