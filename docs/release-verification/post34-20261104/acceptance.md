# Post-PR34 bounded acceptance — 2026-11-04

This records candidate06 local repair after PR #34 merged as `fcbbe42923e1cffca2a2c78dd029147996fd5829`. The production App source remains `ccfad78705861bf4ba2c21d39d50c58091fd8672`, version `0.1.0 (7)`. This is a local acceptance candidate, not a new release or stable support declaration. Exact identities and sanitized measurements are in [verification.json](verification.json). Historical build7 records remain frozen; their source/carrier hashes must not be attributed to candidate06.

## Executed service boundaries

T1 English→Simplified Chinese and T2 Simplified Chinese→English multiline plain translation **passed** in the production App using official DeepSeek `deepseek-flash`. Each used one explicit submit, no retry, with completion observed within 7.062 and 15.038 seconds respectively, below each 120-second deadline. The original [eight-line synthetic fixtures](../build7/bounded-fixtures/manifest.json) retain consecutive empty lines, repeated lines and a trailing newline. Readable translations, line association/layout, edit, clipboard copy verified by UI paste, byte-matching TXT export, history reopen and unchanged prior snapshots passed. These two submits consumed the approved two-request text allowance; no extra translation is authorized by this record.

Provider usage totals 406 input and 149 output tokens (555 total). Using the [DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing/) checked on 2026-11-04, the peak cache-miss input/output price calculation gives US$0.0003006 as an estimated upper amount for these observed tokens, not an actual bill. The prior 139.983-second Keychain authorization timeout remains a missed deadline with no confirmed provider request; the successful runs do not erase it. The App still has no output-token or account billing hard cap.

A1 used one public synthetic Simplified Chinese recording, 20.9283125 seconds, 16kHz mono PCM16, verified as one production-reader chunk. One explicit AiHubMix `whisper-large-v3` submit requested `verbose_json`/segment timestamps and completed within 5.4 seconds of submit, without retry. One HTTP is inferred from one completed chunk and the non-retrying adapter, not an independent network trace. Full text matches the script after ignoring punctuation/whitespace. All five numbered sentence anchors are usable; maximum absolute start difference is 0.3588125 seconds against measured fixture sentence starts. This is a small synthetic sample, not a universal accuracy bound or human phoneme alignment. Duration-based cost estimate is US$0.0006452896 at the [AiHubMix listed rate](https://aihubmix.com/model/whisper-large-v3) of US$0.111/hour checked on 2026-11-04; provider usage and actual billing are unverified.

A1 **text/timestamps passed; paragraph playback and its new-result edit/export/history reopen remain unexecuted**. CUA foreground capture failed with ScreenCaptureKit error 3812; foreground handoff is pending. No second paid transcription is needed to complete those local observations. Historical English/long-file evidence keeps its original model/sample attribution.

## Remaining gates

Gemini G1/G2 and file repair made zero new calls. Read-only isolation review found no verified App-only interruption facility: establishing a rule would require reloading shared network configuration and could affect other work. No outage or network setting change was performed. The approved connection/request/time limits remain unchanged; the current setup is a no-go for G1's 30-second interruption.

The user selected a new ordinary account on the same Mac for ordinary installation and HTTPS cold preparation. Account creation/switch has not occurred. No cold download ran. A fresh App data directory on the developer account and successful cloud calls cannot substitute for this installation gate.

The current PDF engine/resource supplement **passed within its controlled scope**: actual BabelDOC 0.6.4 processed a self-authored one-page English PDF into mono/dual Chinese outputs in 20.48 seconds using two localhost requests and zero Internet-provider requests/US$0. The retained runtime verified 13,565 files and 10 links with zero mismatches. Nonloopback networking and writes to retained runtime were denied; this was not a cold installation. Original input stayed unchanged. PyMuPDF/Poppler inspection found readable Chinese without observed clipping, overlap or tofu. The repeated controlled response verifies the engine path, not cloud translation quality.

Both outputs retain a visible BabelDOC 0.6.4/funstory.ai banner and AI producer. Title wrapping/body merging remain limited reflow. Mono keeps title/author and merges the original producer into creator; dual title/author/creator are empty. Arbitrary source metadata preservation is not guaranteed. Historical real PDF service evidence remains the quality/provider basis; no new DeepSeek PDF success is claimed and the stopped PDF batch remains stopped.

E03/E12 exact-byte comparisons belong to historical build7 source `4579cac`, not candidate06. Candidate06 changes three Core and 26 Native files; their affected sessions/storage/UI are supported by [Spec24 targeted regressions and actual-App evidence](../../verification/spec24-candidate.md). Historical checks are reused only at applicable unchanged boundaries.

Together, historical real provider evidence, applicable E12 and Spec24 UI evidence, actual T1/T2 and this current engine supplement complete the finite technical text/PDF acceptance for #16. This does not complete #17–19 or authorize stable publication.

## Local carriers

Candidate06 source archive SHA-256: `b774e7507e58a1aa879d2f1bad0eb9cbaac71d933b47ed66e5b9f8e204f2782e`; executable SHA-256: `719fb1ef620e1813476b0fe57282b3c79f0dc400cf81c742afbf512236e26978`.

| Local carrier | SHA-256 |
| --- | --- |
| Crosscript-preview-0.1.0-7.dmg | `6da74dfc5eab338a4dbf9a2d4a1aa8222ea644777e0099efaa0946adbc83b97a` |
| Crosscript-preview-0.1.0-7.zip | `d43b0caf8af36a92da6d224e2bdc5d7d96de1d4591410ef610a3b58d39ec97ff` |
| Crosscript-materials-0.1.0-7.tar.gz | `a16e568f67d6e1bee92d36639634093a913102893970147f0222980382b517ca` |

These are locally assembled carriers from the package manifest. Packaging-tool fields such as generated `v0.1.0-preview.7` and `onlineServiceTests: not-run` describe that tool's scope, not a published release or this separate service run. Three carriers were copied to a shared local handoff directory and their hashes verified, without installation. The original DMG has a provenance attribute but no quarantine; the downloaded-app Gatekeeper boundary was not tested. No tag/release/upload/publication was performed. Ordinary installation, Gatekeeper, notarization and stable acceptance remain incomplete. Ad-hoc signing/no notarization remains the accepted limitation.

The source records are the private execution ledger, T1/T2 checks and workspace snapshots, A1 checks and fixture manifest, and local assembled package manifest. This public summary omits absolute local paths, credential/profile IDs and private materials.
