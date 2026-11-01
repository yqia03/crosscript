# Build 5 public delivery and continuing maintenance

[Current evidence index](README.md) · [Verification JSON](public-delivery-verification.json) · [Bounded gaps](gaps.md)

Review for [#10](https://github.com/yqia03/crosscript/issues/10), 2026-11-01. The existing [Crosscript 0.1.0 build 5 Release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5) supplies the matching exact source, preview, third-party materials, App manifest and checksum information. All 28 assets were downloaded without authentication and matched their recorded sizes and SHA-256 digests. This closes the previously pending public-recipient-access observation for these exact bytes. It does not turn publication, source availability or the second-Mac waiver into full technical acceptance.

The maintained English/Chinese READMEs, guides, contribution/security policy and #2–#10 evidence were **merged into `main` on 2026-11-01**, by fast-forwarding to reviewed commit [`2e90ef6`](https://github.com/yqia03/crosscript/commit/2e90ef64ae4a5a26e254703209add483c2e5a6b3). A subsequent remote fetch confirmed that exact `main` commit; `mainMergeFollowUp` in the [verification JSON](public-delivery-verification.json) records this separately from the earlier observations. The earlier anonymous `main/CONTRIBUTING.md` HTTP 200 observation only establishes the page available at that time. The tag, App and all 28 release assets remain frozen. These maintained documents describe current evidence while the versioned source remains the original build input.

## Recipient access and complete asset accounting

[Anonymous asset observations](anonymous-assets-verification.json) record unauthenticated HTTPS GETs at 2026-11-01 09:31 UTC, including exact download URLs, hosted names, original manifest names, sizes and digests. #10 read the actual downloaded `RELEASE-ASSETS.json`, `SHA256SUMS.txt` and binding records, rehashed all 28 downloaded files, and joined every row against those observations and the current Release API identities. There were no missing/extra names or size/digest mismatches:

| Set | Exact comparison |
| --- | --- |
| `RELEASE-ASSETS.json#/payloads` | All 26 filename/size/SHA-256 rows match actual files and their hosted-name mapping. |
| `RELEASE-ASSETS.json#/additionalFiles` | Exactly `RELEASE-ASSETS.json` and `SHA256SUMS.txt`; together with the payloads, exactly the 28 hosted assets. |
| `SHA256SUMS.txt` | All 27 entries match, including the asset index; the checksum file does not hash itself. |
| Release's independent checksum-file identity | 2,493 bytes; SHA-256 `737e23802fe25fc2034192e5d658145d448be528797d0bfd4e6dce5ddc56241b`. This digest also appears in the Release body and recipient integrity record. |
| Final remote preservation observation | At 10:01 UTC, all 28 asset identities, the Release body and annotated tag were unchanged from the initial snapshot. Download counters are outside asset identity. |

The signed App's five targets—project, versioned source, LICENSE, THIRD_PARTY_NOTICES and matching Release—each returned HTTP 200 without login, as did the Issues list and existing contribution page. Their exact URLs/timestamps and method are retained in [the final JSON](public-delivery-verification.json). This is endpoint/byte availability at the observation time; it is not perpetual hosting, publisher authentication, URL activation in a running App or a form-submission test.

Five downloaded ASCII names correspond to unchanged Chinese names in the frozen asset/checksum manifests. The other 23 names are identical. The mapping was checked against the Release body, all 26 payload records, actual downloaded bytes and all 27 checksum entries:

| Hosted download name | Frozen manifest / checksum name |
| --- | --- |
| `RELEASE-READINESS-build5.zh-CN.md` | `发布准备报告-build5.md` |
| `RELEASE-NOTES.zh-CN.md` | `发布说明.md` |
| `INSTALL-UNINSTALL-LIMITATIONS.zh-CN.md` | `安装卸载与已知限制.md` |
| `SECOND-MAC-RESULTS-TEMPLATE.zh-CN.md` | `安装验收结果模板.md` |
| `SECOND-MAC-CHECKLIST.zh-CN.md` | `第二台Mac安装验收清单.md` |

Download the full set into a new empty directory. Establish the checksum-file digest from the Release, restore those five original names without overwriting existing files, then run `shasum -a 256 -c SHA256SUMS.txt`; the [Release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5) provides the exact `mv -n` commands. Alternatively, compare each hosted file directly using the mapping and expected digest. Preserve the original asset/checksum bytes. Matching hashes establish byte correspondence, not authenticated publisher identity.

## Same-version source, App and materials

The [index identity table](README.md#exact-source-app-and-materials-linkage) gives immutable download URLs and full primary hashes. The source archive is **[Crosscript-source-0.1.0-5.tar.gz](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-source-0.1.0-5.tar.gz)**, SHA-256 `cca34e44250e281e5fc3509610b16a6f0d10259cf5ec50ddc536be08711de291`. GitHub's automatic source ZIP/tarball is a separate generated object; it cannot replace this App-bound archive. A moving development branch is also a different source identity.

The annotated tag object is `e8e62031cc9a84934dc1b95e3c2f7bc564e83f95`; it peels to public root `47c1b0cb53326da4b6590fc873ca91016139d659`. The signed App embeds build-input commit `2c57e25d44f879904cf4208074ba5bf21a01d8e2` and that exact source archive digest. Both original commits have tree `ffa50501cbe21e0c9141d40a912db8e0dd8282bb`; the independent public history intentionally excludes private development history. #10 checked tag peeling/tree and cross-record source identities; [baseline](baseline.md) supplies the full 371-file archive/manifest/checkout byte check.

The final JSON records each direct asset join in `RELEASE-BINDING.json`: source archive and file manifest, preview ZIP, App tree manifest, verification helper, materials archive and current materials index. It also checks the actual build/source-review/package/material verification records and #8 recipient inputs against downloaded digests. Commit/tree/archive and signed metadata agree across build, package, source-review, current-index and reconciliation records; the App executable digest agrees with build evidence. All five license-UI source inputs match `SOURCE-FILES.json`, and all five displayed link targets match the anonymous observations.

`CURRENT-MATERIALS-INDEX.json` fixes the runtime ID and manifest digest, four current-index digests and selected overlay paths. These identities agree with the binding, baseline and [#7 reconciliation](source-distribution-verification.json). The material archive digest and its internal delivery-index/checksum digests agree with the final binding and complete [material-byte check](materials-byte-verification.json). That reused check covers all 13,199 regular members, 13,197 delivery-index entries and 13,198 checksum entries. #10 does not pretend to repeat the full extraction/build reviews: #2–#5 and #7 preserve their exact source/notice/producer limits, and [#8](candidate-integrity.md) preserves actual signed-App/static verification scope.

The result is a complete same-version **delivery set** under the recorded manifests and linkage. It does not establish every original producer recipe, all recipient rebuilds, universal privacy/rights clearance, all-stack legal compliance or complete workflow acceptance. Those boundaries remain individually tracked below.

## Current guidance, historical records and user boundaries

The Release body records the later 2026-10-30 publication approval and explicit build 5 B01–B06 waiver. #10 compared its source identities, main archive hashes, checksum digest, filename mapping and waiver against the frozen objects. [Maintained English](../../../README.md) / [中文首页](../../../README.zh-CN.md), [English guide](../../getting-started.md) / [中文使用说明](../../getting-started.zh-CN.md) and [user-material review](user-materials.md) retain the same version/download and capability boundaries on `main`.

The downloadable `README.md` / `README.zh-CN.md` are historical delivery-folder cover sheets, distinct from the maintained repository homepages and the READMEs inside the exact source archive. Frozen `readyForPublication=false`, `pending`, old 404 observations and “not authorized/published” statements describe their 2026-10-29 preparation stage. `RELEASE-BINDING.json` already resolves the earlier outer-material assembly binding; the later Release supplies publication approval, and the dated anonymous GETs supply actual access evidence. None of these later facts rewrites an earlier test result or makes B01–B06 pass. The maintained docs tree contains new audit documents and is not the original `ffa505...` build input.

Crosscript remains the project/release brand; the bundle/executable is `TranslationWorkbench.app` / `TranslationWorkbench` and the signed display name is `翻译工作台`. This is arm64 with a declared macOS 14.2 minimum; that exact OS was not physically tested. Signing is ad-hoc integrity signing, without Developer ID publisher authentication or Apple notarization. #8's fresh static pass did not launch the App or assess ordinary-Mac Gatekeeper, permissions or cold HTTPS setup. Preserve system security protections and follow the installation guide.

The four workflows remain Text/Markdown Translation, PDF Translation, Recording/Post-recording Transcription and Live Translation with bilingual text. Provider/model/language coverage, arbitrary PDF/OCR quality, official OpenAI recording success and long Gemini/reconnection/gap-repair behavior retain the stated limits. Local retention does not imply offline processing: explicit processing, connection checks and live sessions can upload content and incur charges, including failed/incomplete work. PDF has 22 bundled and 245 remaining pinned HTTPS inputs (359,471,768 bytes), with further unpacking/processing space required. No live/paid request, stopped PDF batch or second-Mac run was performed or authorized by this delivery audit.

Own code remains **AGPL-3.0-only**, including compliant commercial use; third parties keep their actual terms and applicable “or later” choices. Public source/material availability is distinct from every technical or legal conclusion.

## Feedback, contributions, security and migration

Daily development and task tracking are concentrated in [yqia03/crosscript](https://github.com/yqia03/crosscript) and its [Issues](https://github.com/yqia03/crosscript/issues). The final JSON retains the 09:38 UTC verified repository description, release homepage and all nine topics (`apple-silicon`, `babeldoc`, `gemini`, `macos`, `pdf`, `swift`, `swiftui`, `transcription`, `translation`), plus public visibility and Issues enabled. These settings were applied/verified in #6; #10 made no settings change.

Use [new issue](https://github.com/yqia03/crosscript/issues/new) for ordinary bugs/support, with app/build, macOS/chip, workflow, provider/model, expected/actual result and safe reproduction. Follow [CONTRIBUTING.md](../../../CONTRIBUTING.md) for contribution licensing and meaningful checks. Private vulnerability reporting is verified enabled; use [its private form](https://github.com/yqia03/crosscript/security/advisories/new), following [SECURITY.md](../../../SECURITY.md). At 10:06 UTC the unauthenticated issue and vulnerability entry URLs each correctly redirected to GitHub login with their destination retained and returned HTTP 200; the contribution page returned HTTP 200 directly. Authentication is required to submit; no report, advisory, issue or other message was sent, and successful submission was not tested. There is no guaranteed response/fix deadline.

The original private GitHub repository **was deleted**, as confirmed by the user/tracker migration fact; this is not a new anonymous test of a private endpoint. It is not recreated or required for public development or restore. The retained recovery set stays nonpublic: referenced Git history plus 3,655 selected regular working files, 1,512,100,829 bytes, with selected refs/status/bytes/modes successfully restored offline. [Baseline recovery scope](baseline.md#nonpublic-recovery), [safe aggregate record](recovery-verification.json) and G12 enumerate exclusions. It does not cover every ignored/external raw interview, recording/output, other worktree's dirt, reflog-only object, config/hook/xattr, actual user data or Keychain. Private archive locations, manifests, history and contents are not part of the public evidence.

## All continuing gaps and smallest follow-through

The authoritative descriptions and evidence remain in [gaps.md](gaps.md). Audit-ticket closure records the completed audit; it does not close missing historical proof. These stable IDs survive #10:

| ID | Final disposition | Smallest next action if stronger evidence is required |
| --- | --- | --- |
| G01 | Retained: independent original-file entitlement certification absent. | Identify the disputed exact path/hash and obtain its origin/permission declaration. |
| G02 | Retained: targeted privacy scan has bounded detection scope. | Review a concrete changed path/finding with explicit rules; publish no sensitive values. |
| G03 | Retained: qualified historical producer recipes/associations. | Obtain the exact missing configuration/association for the historical object. |
| G04 | Retained: optional/static linked membership not exhaustive. | Inspect that concrete component's build configuration/static linkage. |
| G05 | Retained: universal recipient rebuild/replacement not executed. | Select an explicitly arranged exact component/replacement seam and record new identities/results. |
| G06 | Retained: three pip launcher RECORD mismatches, installed hashes known. | Inspect producer rewrite policy and expected/actual launcher bytes; a byte fix requires a new runtime/candidate. |
| G07 | Retained: earlier OTF→TTF conversion chain incomplete. | Obtain pinned external conversion inputs/recipe, or scope a separate reviewed derivative. |
| G08 | Retained: model conversion/training and o200k-specific terms qualified. | Obtain exact provenance or authoritative scope statement; revisit ONNX only on concrete inclusion/change. |
| G09 | Retained: universal real-output notices/producer behavior unverified. | Arrange one exact output scenario and inspect its metadata/terms; stopped PDF work remains stopped. |
| G10 | Retained: B01–B06 not-run, explicitly waived; physical OS/ordinary-Mac/data/Keychain gaps remain. | Keep the [#9 status](second-mac.md); a future supplementary run requires a new explicit arrangement. The existing release needs no retroactive second-Mac gate. |
| G11 | Retained: workflow/provider/quality/long-session limits. | Keep user-facing limits; scope one exact acceptance question and budget only if separately authorized. |
| G12 | Retained: private recovery covers only the selected set. | Privately inventory and restore-test any specifically required excluded category; publish safe aggregates only. |
| G13 | Public-recipient access, all name mappings and final #8→#9→#10 handoff now observed; historical record interpretation retained. Maintained docs were merged into `main` on 2026-11-01 at reviewed commit `2e90ef6`. | The reviewed branch merge is complete; retain frozen history and dated observations. Later access-change claims need new dated evidence. |
| G14 | Retained: historical full suites and paired product review not recorded. | Select exact candidate/seams and authorized local scope if needed; a docs review cannot become historical product acceptance. |

No silent repair is required merely to disclose these limits. Changing frozen source/build inputs, App metadata, runtime/components/resources or material bytes, or publishing another version, requires a **new explicit scope**, fresh affected source/tree/archive/build/runtime/material identities and affected #8–#10 checks. The audit supplies no new provider budget, second Mac, rebuild, re-sign, frozen-asset overwrite or publication authorization. No production behavior or tests were added; validation here was read-only byte/index/binding/link review, JSON/relative-link/privacy checks and diff checks.
