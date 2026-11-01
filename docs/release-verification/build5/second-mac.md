# Build 5 second-Mac status and future supplement

Recorded 2026-11-01 for [#9](https://github.com/yqia03/crosscript/issues/9). The [current Release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5) records the owner's **2026-10-30 explicit waiver of build 5 second-Mac B01–B06 and approval to publish**, with knowledge of the OpenSSL replacement. **B01–B06 were not run.** Release approval, actual test results and a possible future arrangement are separate records. Build 4 was accepted on a user declaration/instruction without independent log review; it supplies no build 5 second-Mac pass. Publication or closing this documentation ticket adds no execution evidence.

The [machine status](second-mac-verification.json) preserves all six `not-run` results, the waiver and the exact frozen checklist/template identities. No second-Mac session is scheduled or authorized by this supplement. Accurate registration of the existing waiver, unexecuted results and scoped gaps completes this ticket; actual supplementary testing is **not a new gate for the already published build 5**.

## Exact candidate covered by the waiver

The [#8 candidate record](candidate-integrity.md) and [bounded JSON](candidate-integrity-verification.json) supply the bindings below. The App is `TranslationWorkbench.app`, executable `TranslationWorkbench`, bundle ID `dev.uown.translation-workbench`, version **0.1.0 (5)**, arm64, declared minimum macOS **14.2**, ad-hoc signed and not notarized. Ad-hoc integrity does not authenticate a Developer ID publisher.

| Identity | Exact value |
| --- | --- |
| Tag / public root | `v0.1.0-preview.5` / `47c1b0cb53326da4b6590fc873ca91016139d659` |
| Original build input / shared source tree | `2c57e25d44f879904cf4208074ba5bf21a01d8e2` / `ffa50501cbe21e0c9141d40a912db8e0dd8282bb` |
| Preview ZIP | `Crosscript-preview-0.1.0-5.zip`, 169,789,128 bytes; SHA-256 `86b4693ce411664cfe388e29efe09280ec22ab6f696701baf1854d536f590f97` |
| App executable | SHA-256 `da0e75ea0c65631cdf43d64e90b3f6a82f97d3482d4a8521ed14437f9f8ff41d` |
| Full App manifest | `APP-MANIFEST.tsv`; SHA-256 `766edf1577aa1884b7e3b52d390d851ccea011d5b1831f6b5ee2bcdd8e04e90d` |
| Exact source archive | `Crosscript-source-0.1.0-5.tar.gz`; SHA-256 `cca34e44250e281e5fc3509610b16a6f0d10259cf5ec50ddc536be08711de291` |
| Third-party companion | `Crosscript-third-party-0.1.0-5-materials-v4.tar.gz`; SHA-256 `25049788ea1f9b1c638164e2743d0089b71d828ce0729c28d02238bfd375cf89` |
| PDF runtime / manifest | `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3` / SHA-256 `2fce7f0f1a5c1ef758d59e6ae7b529e8d953920baed9f6561f71a3ec2aeea64b` |
| OpenCV wheel | `opencv_python_headless-5.0.0.93-3crosscriptopenssl-cp37-abi3-macosx_14_0_arm64.whl`; SHA-256 `4f8048e641ec2a06c70e1e092cd4271ebd5cf94d9311b3125992dcc5efa8638d` |
| Replaced OpenSSL 3.6.0 libcrypto | `cv2/.dylibs/libcrypto.3.dylib`; SHA-256 `13aa519f1e6d13d3eb3968448e1166e5de03b70fa7b4ec5282e5c21318ab855e` |
| Replaced OpenSSL 3.6.0 libssl | `cv2/.dylibs/libssl.3.dylib`; SHA-256 `a2bdd0fd427991bdf846b87f1af9f697c6fae9f208accdb9dfad142b958b319d` |

The App embeds the original build-input commit and source archive digest; the public root has the same original source tree and separate history. Later audit documentation is outside that tree. The two OpenSSL libraries were built from unmodified pinned official OpenSSL 3.6.0 source (archive SHA-256 `b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9`), with recorded configuration/toolchain, and integrated as wheel build `3crosscriptopenssl`. Of 451 installed native objects, 449 remain unchanged from build 4; this does not inherit build 4 workflow acceptance. See [native source/config/output evidence](native-components.md#source-configuration-and-notice-joins).

#8's fresh read-only check used an anonymously downloaded ZIP on the audit host, without launching the App. Full tree/modes, metadata, arm64, strict ad-hoc signature and input preservation passed; quarantine was not observed, Gatekeeper was not assessed. This is no browser-origin download, ordinary-Mac installation, first-launch, permission or PDF acceptance. Historical isolated runtime preparation used fixed cached inputs under deny-network; it is no true cold HTTPS download.

## Frozen checklist and template coverage

The frozen [SECOND-MAC-CHECKLIST.zh-CN.md](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/SECOND-MAC-CHECKLIST.zh-CN.md) and [SECOND-MAC-RESULTS-TEMPLATE.zh-CN.md](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/SECOND-MAC-RESULTS-TEMPLATE.zh-CN.md) remain unchanged. They are instructions and an empty template, not execution evidence. Their original checksum names are `第二台Mac安装验收清单.md` and `安装验收结果模板.md`; use the [asset filename mapping](anonymous-assets-verification.json). Frozen preparation/pending wording remains historical; the later Release supplies the approval.

| Frozen item; actual status | Covered instructions | Scope needing the future supplement |
| --- | --- | --- |
| B01 — **not-run** | Full delivery checksums; actual installed App read-only helper; versions, tree, architecture and strict signature | Explicit browser/channel and download/quarantine evidence; environment/network record |
| B02 — **not-run** | Ordinary Apple Silicon Finder install/open, existing data retained, quarantine/system prompts observed; optional user-decided per-App exception | Browser origin is not explicit; permission grant/denial/recovery has no separate case |
| B03 — **not-run** | Both languages, selectable full license/scroll, five versioned links | Production App/browser activation remains unobserved; old prepublication 404 wording is no current link result |
| B04 — **not-run** | No developer Python/Homebrew/Xcode; normal App prepare, new v3/health, v2-cache distinction | Failure/retry not explicit; true cold HTTPS versus existing cache must be recorded |
| B05 — **not-run** | Actual installed libcrypto/libssl hashes, wheel build and v3 inventory identity | No substitute for normal installation or PDF translation acceptance |
| B06 — **not-run** | Quit/relaunch, reuse/health/inventory, existing data retained, post-run App helper | History reopening and actual export need separate cases |

The original results template has only device/OS, receipt/checksum, installation/cache state and B01–B06 rows. It does not capture browser/network, permission decisions, failure/retry, history/export or detailed before/after evidence. The following maintained supplement fills those documentation gaps without rewriting the originals or claiming execution.

## Future checklist — all not-run; new explicit arrangement required

Before any future run, separately agree the participant/device, exact candidate, bounded cases, network/download permission and local synthetic data. Distinguish local permission/download checks from any provider operation. No stopped PDF batch, real-time/cloud/paid probe or old budget is reactivated. This checklist itself grants no execution authorization.

Record date/time, chip/model (no serial number), exact macOS version/build, browser/version, ordinary account/security state, network/proxy conditions (no private address/SSID), existing App/runtime/cache/data state, archive/source/material hashes and pre/post evidence references. Confirm no development environment is installed or added: no Xcode/CLT, Homebrew or developer Python dependency. Use system tools and the supplied helper. Do not clone development caches, credentials or user files. A result on another OS cannot prove physical macOS 14.2 compatibility.

| ID / links to frozen cases | Future operation and bounded observation | Current result |
| --- | --- | --- |
| S01 / B01 | Obtain the exact ZIP through a real browser from the versioned Release on that Mac. Record download channel/URL and browser; observe archive and extracted App quarantine before opening, without changing it. Preserve absent/present values and prompts; absence cannot be described as quarantined first launch. Verify trusted SHA256SUMS digest, 27 entries and five filename mappings before use; retain ZIP and full App-manifest identities. | **not-run** |
| S02 / B01–B02 | Finder extract and normal installation to selected location, backup owned data as arranged, run the frozen read-only helper on this actual App before launch, then open normally. Record exact system prompts and outcome. If the user explicitly chooses an applicable per-App exception, record that decision and normal system UI path. Stop on hash/signature mismatch, malware or modified/damaged alerts. Keep quarantine; no global protection changes, attribute deletion or re-signing. | **not-run** |
| S03 / B02 | With separately arranged synthetic local audio and one chosen source at a time, record microphone and screen/system-audio permission requests actually triggered, grant/deny choices, error behavior and recovery through normal per-App settings. Merely opening a workspace is not capture or permission acceptance. Do not reset global permission databases or access private recordings/Keychain. Unarranged source/denial paths stay not-run; no provider connection is needed to claim only local permission behavior. | **not-run** |
| S04 / B03 | In the actual App inspect both language views, complete selectable offline own/third-party texts, scrolling and local material entry. Activate five links and record exact destinations: project, tag, own license, notices, matching Release/materials. HTTP availability and actual browser activation are separate observations. | **not-run** |
| S05 / B04–B05 | After explicit download consent, use only normal PDF preparation. Record preexisting v2/v3/cache state, progress, all applicable HTTPS inputs versus cache reuse, newly created v3, health/inventory, wheel build and both OpenSSL hashes. A cached or already prepared runtime is not first/cold download. Do not delete real user caches/runtime to manufacture a cold state. | **not-run** |
| S06 / B04 | If separately arranged, observe a natural or controlled recoverable preparation failure (for example, temporary network loss) and normal retry after recovery; record stage/error, partial state, retry outcome and final health/inventory. No library/inventory tampering. If no failure occurs, leave this case not-run; successful first prepare is no retry test. | **not-run** |
| S07 / B06 | Quit/relaunch and revisit PDF; record v3 reuse and health/inventory, original data/runtime preservation. Distinguish an observed first prepare from reuse of a preexisting installation. | **not-run** |
| S08 / supplement | With agreed synthetic local material, reopen saved history after relaunch and export the available selected local result through normal controls; record workflow, input/output hashes, format and preservation. Do not request translation/transcription/live service to manufacture a result. Missing suitable local result means not-run; any future PDF/provider output acceptance needs its own explicit arrangement and scope. Do not generalize one history/export check to all four workflows. | **not-run** |
| S09 / B06 | Repeat the same read-only App helper after all arranged cases; retain pre/post tree/manifest/signature evidence and archive digest, verify no signed App changes and separately record runtime inventory/health. Preserve sanitized errors, even when a case fails or cannot run. | **not-run** |

Use the [future result template](second-mac-results-template.md) for a separately arranged session. Record each B/S case as pass, fail or not-run, with observed evidence and reason; a waiver is no fourth test outcome. Any required case missing or failed prevents claiming that session's whole supplement passed. Optional/unarranged cases remain explicit unknowns, not silently dropped.

## Retained limits and follow-through

[G10](gaps.md) remains: no build 5 second-Mac execution, physical macOS 14.2, real ordinary-Mac cold HTTPS preparation, Gatekeeper/quarantine/permissions acceptance, existing-user data/Keychain migration or uninstall/secure-erasure result. [G11](gaps.md) retains general PDF quality/OCR, real cloud/provider and other workflow limits; [G14](gaps.md) retains full-suite/product-review gaps. S08 is a future local history/export case and cannot close real PDF/provider acceptance. Do not inherit historical cost budgets or call stopped probes.

If source, build input, signed metadata, App/runtime/component bytes or entitlements change, preserve build 5 and bind a separate clean source/tree/archive and new candidate/runtime/material identities through [#7](https://github.com/yqia03/crosscript/issues/7) / [#8](https://github.com/yqia03/crosscript/issues/8) before interpreting future installation results; [#10](https://github.com/yqia03/crosscript/issues/10) verifies the corresponding public delivery. A future result must identify its actual candidate and cannot be backdated into this waiver.

This ticket checked local Release/checklist/template snapshots, #8 identity agreement, coverage, JSON, links and diff/privacy scope only. No App launch/build/test, device interaction, browser download, permission change, network preparation, service request or frozen-asset change was performed for #9.
