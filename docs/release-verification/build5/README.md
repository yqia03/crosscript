# Build 5 current evidence index

Reviewed 2026-11-01 for [#7](https://github.com/yqia03/crosscript/issues/7). The published version is [v0.1.0-preview.5](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5), App **0.1.0 (5)**. The source, selected component materials and preserved release bytes are traceable within the scope below. Publication approval, byte agreement, actual executed tests and remaining evidence limits are separate facts. This index is maintained documentation; the tag, signed App and 28 release assets remain frozen.

For use and installation, start with the [English guide](../../getting-started.md) / [中文使用说明](../../getting-started.zh-CN.md). For unresolved evidence, use the stable IDs in [gaps.md](gaps.md). Audit-ticket closure does not turn those items into passes.

## Current status and evidence routes

| Surface | Evidence entry | Established scope / next owner |
| --- | --- | --- |
| Frozen identities and private recovery | [Baseline](baseline.md), [baseline JSON](baseline-verification.json), [coverage ledger](component-coverage.json) | #2: source/asset/index byte correspondence and bounded private recovery; no user-data backup claim |
| Python, interpreter and engine integration | [Python/engine](python-engine.md), [86 component records](python-engine-verification.json) | #3: all selected component/source/notice/build associations; native producer and replacement limits remain explicit |
| Native distribution | [Native components](native-components.md), [451 object records](native-verification.json) | #4: exhaustive regular Mach-O membership, nested material joins and structural load closure; not every original build or static dependency proved |
| Fonts, CMaps, model and tokenizer | [Assets](assets.md), [asset verification](assets-verification.json) | #5: all 182 selected payloads and referenced material scope; provenance and output-notice limits retained |
| Public guides, sample and images | [User materials](user-materials.md), [verification](user-materials-verification.json) | #6: actual entry points, original synthetic PDF, two metadata-cleaned historical license-component captures; no full-App screenshots or workflow run |
| Source/release/material reconciliation | [Reconciliation JSON](source-distribution-verification.json), this index | #7: complete #2-to-#3/#4/#5 joins and correct historical/current interpretation |
| Final signed App / ZIP binding | [Candidate integrity](candidate-integrity.md), [bounded verification](candidate-integrity-verification.json) | #8: historical clean Release build and exact focused-test scopes, actual package binding and fresh anonymously downloaded App static pass; no full suite, full-App launch or ordinary-Mac acceptance |
| Installation and compatibility | [#9](https://github.com/yqia03/crosscript/issues/9), [baseline identities](baseline.md), frozen installation limitations | Second-Mac B01–B06 not run; explicitly waived 2026-10-30. macOS 14.2 physical testing and existing-user data/Keychain migration remain unverified |
| Public recipient access and final follow-through | [Anonymous asset observations](anonymous-assets-verification.json), [#10](https://github.com/yqia03/crosscript/issues/10) | All 28 assets anonymously retrieved and matched on 2026-11-01; #10 consolidates public links, final hashes and continuing gaps |

The owner's 2026-10-30 publication approval and second-Mac waiver are recorded in the current Release. They supersede earlier publication-pending decisions, without changing any historical test outcome. Build 4 acceptance is never inherited. Stopped PDF batches and live/paid probes remain stopped.

## Exact source, App and materials linkage

| Object | Immutable identifier |
| --- | --- |
| Public root / peeled tag commit | `47c1b0cb53326da4b6590fc873ca91016139d659` |
| Annotated tag object | `e8e62031cc9a84934dc1b95e3c2f7bc564e83f95` (`v0.1.0-preview.5`) |
| Original build-input commit, signed into App metadata | `2c57e25d44f879904cf4208074ba5bf21a01d8e2` |
| Shared original source tree | `ffa50501cbe21e0c9141d40a912db8e0dd8282bb` |
| Exact source archive | [Crosscript-source-0.1.0-5.tar.gz](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-source-0.1.0-5.tar.gz), SHA-256 `cca34e44250e281e5fc3509610b16a6f0d10259cf5ec50ddc536be08711de291` |
| Source file manifest | [SOURCE-FILES.json](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/SOURCE-FILES.json), 371 files; SHA-256 `4cd184504383e5c5bd085d140c1c16ce1d167d2501e284e6bdbb8dcabe8765f4` |
| Preview ZIP | [Crosscript-preview-0.1.0-5.zip](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-preview-0.1.0-5.zip), SHA-256 `86b4693ce411664cfe388e29efe09280ec22ab6f696701baf1854d536f590f97` |
| Third-party companion | [Crosscript-third-party-0.1.0-5-materials-v4.tar.gz](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz), SHA-256 `25049788ea1f9b1c638164e2743d0089b71d828ce0729c28d02238bfd375cf89` |
| Selected material index | [CURRENT-MATERIALS-INDEX.json](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/CURRENT-MATERIALS-INDEX.json), SHA-256 `05d65f613e87a09b1434466083d3ac191905ca053979f7fd9a2fa76bd4f8dadd` |
| Runtime selection | `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`; manifest SHA-256 `2fce7f0f1a5c1ef758d59e6ae7b529e8d953920baed9f6561f71a3ec2aeea64b` |

The public root has independent history and the same original source tree as the build input. The App embeds the **build-input commit and exact source archive digest**, not the later public root commit. Its license window links the versioned source tag, LICENSE, notices and matching Release. [LICENSE-UI-VERIFICATION.json](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/LICENSE-UI-VERIFICATION.json) binds the actual isolated component and language source; anonymous link observations are described in [user materials](user-materials.md). A moving `main` or GitHub-generated source ZIP is not a substitute for this source archive.

[BUILD-EVIDENCE.json](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/BUILD-EVIDENCE.json) records a clean source, fresh external Swift build directory and exit 0, unchanged source before/after, restricted environment, build/log identities, and signed source metadata. Its toolchain is Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), SDK 27.0, arm64, macOS 26.6.2 build 25G83. The build command is `python3 -B scripts/release/build-bound-candidate.py --source <clean-source-checkout> --output <new-independent-directory>`. [RELEASE-BINDING.json](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/RELEASE-BINDING.json) joins source/manifest, executable, ZIP, App manifest, selected runtime and full material archive. These are historical executed build/static results, not a newly reproduced build or authentication of the publisher.

The release source contains App/bridge/installer/maintenance/build/packaging scripts and selected bundled inputs. The managed runtime selects **267 inputs: interpreter + 84 wheels + 182 assets**, with bootstrap pip inside Python. **22 inputs are bundled, 245 are fixed HTTPS inputs.** Recipient source/notices/build records are delivered even where selected binary inputs are downloaded separately. Follow companion `CURRENT-INDEX.json` and `current/`, then their explicit origin pointers; `origin-materials/` and the old `upstream-runtime-manifest.json` do not override current selection. Exact recipes and external input limitations are in the scoped reports above.

## Complete component and delivered-byte reconciliation

[Source/distribution verification](source-distribution-verification.json) checks every #2 coverage pointer and identity, and every available size/digest (pip is contained, without a separate artifact digest) against the actual four current indexes and their index digests. It joins all 86 #3 component records and 85 selected interpreter/wheel pointers, all 451 #4 native object pointers and every #5 asset allocation. The #5 report records 182/182 material, installed and manifest/artifact joins. Counts overlap; 451 native members are nested in interpreter/wheels and are not 451 extra manifest downloads.

| #2 index | Rows | Downstream reconciliation |
| --- | ---: | --- |
| `current/runtime-artifact-index.json` | 267 | 85 #3 interpreter/wheel rows + 182 #5 assets; no unassigned/missing/extra pointer |
| `current/component-index.json` | 86 | 85 #3 exact selected-digest rows plus contained pip identity/source records; #4 supplies compiled/nested scope |
| `current/native-index.json` | 451 | 451 #4 current-index pointers; all report installed byte matches; separate own App executable belongs to #8 |
| `current/asset-index.json` | 182 | 182 #5 allocations and complete reported byte/manifest joins: 34 fonts, 146 CMaps, model, tokenizer |

[materials-byte-verification.json](materials-byte-verification.json) reuses the root's completed full check: **13,199 regular archive members**, 13,197 delivery-index entries and 13,198 checksum entries match; all expanded regular-file bytes match the archive. The delivery and checksum files' own digest identities are retained. [anonymous-assets-verification.json](anonymous-assets-verification.json) records all 28 downloaded asset bytes and the five unchanged hosted-name/manifest-name mappings. These complete checks bind the expanded material reports to actual delivered archive bytes; they do not extend the reports' source completeness, original-build or legal scope.

Two evidence counters/labels were corrected during this join: baseline `releaseCommit` previously held the annotated tag object; it now contains the peeled public commit, with the original retained as `releaseTagObject`. The selected OpenCV wheel's compact `nativeMembers=0` counter was inconsistent with its already documented 100-member review; a fresh read-only magic scan of the actual selected ZIP confirms **100**. The corrected machine record and reconciliation describe that check. No frozen source, wheel or asset changed.

## Source membership, rights and privacy review scope

The released [PUBLIC-SOURCE-REVIEW.json](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/PUBLIC-SOURCE-REVIEW.json) fixes the 371-file source/archive and original tree. Its privacy check scanned 320,358,129 expanded bytes: 371 top-level files and 502 members of the two nested wheels, finding zero unresolved high-confidence matches. Exceptions are exact-hash public upstream self-test PEM blocks, build paths and parser marker strings. This is a targeted recognizable literal/PEM scan, not proof against arbitrary encoded secrets or an exhaustive independent rights audit.

| Actual public material | Available origin/rights/privacy evidence | Precise limit |
| --- | --- | --- |
| Original Swift/integration, scripts, tests and necessary docs | Exact 371-file manifest, clean-tree review, [snapshot selection](../../snapshot-changes.md), [testing scope](../../testing.md), own-code declarations in [LICENSE](../../../LICENSE) / [notices](../../../THIRD_PARTY_NOTICES.md); targeted archive/nested scan above | Own-code license statement is the maintainer's entitlement declaration; there is no independent file-by-file authorship/rights certification. Included tests are not an execution claim. See G01/G02. |
| Third-party adaptations, wheels, native libraries and resources | Complete selected origin/current record joins in #3/#4/#5; full license/attribution, modifications, source and build records retain their specific scopes | Preserve file-level GPL/AGPL/MPL/LGPL/OFL and upstream “or later” branches; source presence is not proof of all production configurations or every possible legal condition. G03–G08. |
| Original synthetic PDF and retained controlled test generation | [Fixture declaration](../../../tests/fixtures/pdf/README.md), deterministic stdlib generator; #6 regenerated the exact 745-byte PDF and inspected content/metadata | No user document or imported art/font payload in that fixture; no real translation acceptance inferred. |
| Application icon | [Icon provenance and three hashes](../../asset-provenance.md#app-icon): generated for this project 2026-10-20 and maintainer-selected; original/preview/ICNS and packaging script retained | AI generation provenance does not claim exclusive rights or trademark clearance. |
| Two newly published historical license-component image derivatives | #6 visible-content and PNG metadata inspection, sanitized metadata, byte-identical compressed image/pixel evidence | Isolated component only, no private body/key/username/path visible; no full-App or workflow demonstration. |

The later maintained guides, two #6 image derivatives and #7 summaries are additions to the development tree; they are covered by the separately recorded #6 image/sample/privacy checks and #7 relative-link, JSON and private-path/credential-pattern review, not retroactively included in the frozen 371-file scan.

Private logs, unknown-rights historical samples, real-service probe apps and original repository history were excluded from the public snapshot. Public source publication alone is never used as proof of completed review. Required stronger assertions that lack evidence remain explicit in [gaps](gaps.md), rather than being silently promoted to compliance or infringement findings.

## Private recovery and historical records

The deleted original private remote is not recreated or needed for restore. [recovery-verification.json](recovery-verification.json) records an offline-tested private bundle plus working-file archive: referenced Git history and **3,655 selected Git-visible/previously audited regular working files**, 1,512,100,829 bytes, including selected dirty/untracked development materials. All selected restored bytes/modes, saved refs and status matched. Private manifests, archive contents and locations stay nonpublic.

This is not evidence that every interview, raw recording or unreviewed output on the Mac is backed up. Ignored/external raw assets, external historical release evidence, other worktree dirt, reflog-only/orphan objects, config/hooks, xattrs, actual user recordings/application data and Keychain are outside that recovery set. External evidence was read in place. G12 records the exact remaining recovery scope; no broader backup success is claimed.

Current READMEs, guides, support/security pages and this evidence directory describe the published state. The frozen tag/archive/App and historical preparation pages preserve `pending`, `readyForPublication=false`, old 404 observations and precursor IDs as dated records. Banners added in #6 and these index links explain their scope; `docs/snapshot-changes.md` is also historical source-selection history. Later publication and anonymous access observations do not rewrite those original records. #7 adds documentation on the development branch, whose tree necessarily differs from the original `ffa505...` tree; it is **not** a newly bound build 5 source tree.

## Changes requiring new identities

If future work changes source/build-input documents, bundled resources, component bytes, runtime selection or signed metadata, freeze a separate clean source commit/tree/archive and the affected runtime/material identities. Then #8 must verify that new candidate's build/App/package/signature binding, #9 must state its own installation results and #10 must verify its public delivery. Preserve this release's originals. No new candidate is needed merely to record this audit or disclose a historical evidence limit; no missing producer proof is converted into a license violation.

Checks here are read-only index/digest/pointer reconciliation, annotated-tag peeling, a bounded wheel-member recount, source-membership/provenance review, JSON parsing, relative-link/privacy review and diff checks. Completed full archive/asset checks are reused with their exact scope. No behavior change or artificial TDD test was added, and no App build/launch, real provider request, Keychain access, paused PDF batch, push or publication was performed for #7.
