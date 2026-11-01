# Build 5 baseline and recovery record

[Current evidence index](README.md) · [Bounded gaps and next actions](gaps.md)

Evidence review for [#2](https://github.com/yqia03/crosscript/issues/2), checked 2026-11-01. The baseline is the already published [v0.1.0-preview.5](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5), not a new candidate or version. This record adds evidence; it changes no frozen App, runtime, source archive or release asset.

The Release records publication on 2026-10-30 and the owner's explicit waiver of build 5 second-Mac B01–B06. Those checks were **not run**. Frozen preparation records retain their earlier `pending`, `readyForPublication=false` and unpublished wording. Publication authorization, public availability and technical test results remain separate facts.

## Source and distribution identity

| Object | Exact identity |
| --- | --- |
| Public source commit | `47c1b0cb53326da4b6590fc873ca91016139d659` |
| Original build-input commit, embedded before signing | `2c57e25d44f879904cf4208074ba5bf21a01d8e2` |
| Shared source Git tree | `ffa50501cbe21e0c9141d40a912db8e0dd8282bb` |
| Exact source archive | `Crosscript-source-0.1.0-5.tar.gz`, 168,612,071 bytes; SHA-256 `cca34e44250e281e5fc3509610b16a6f0d10259cf5ec50ddc536be08711de291` |
| Preview archive | `Crosscript-preview-0.1.0-5.zip`, 169,789,128 bytes; SHA-256 `86b4693ce411664cfe388e29efe09280ec22ab6f696701baf1854d536f590f97` |
| Materials archive | `Crosscript-third-party-0.1.0-5-materials-v4.tar.gz`, 1,667,240,667 bytes; SHA-256 `25049788ea1f9b1c638164e2743d0089b71d828ce0729c28d02238bfd375cf89` |
| Runtime | `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`; BabelDOC 0.6.4; CPython 3.12.15 |
| Selected runtime manifest | SHA-256 `2fce7f0f1a5c1ef758d59e6ae7b529e8d953920baed9f6561f71a3ec2aeea64b` |
| Bundled runtime index | SHA-256 `bea9c7455ae8b164029964e9f9b244af2ca141b74c77a7c80b86aa500ca999ac` |

The reviewed public root deliberately omits private Git history. Its tree matches the build-input tree; the different commit IDs do not identify different source content. `SOURCE-FILES.json` describes 371 files. This review compared every source archive file's size, digest and mode against that manifest, and every corresponding release-checkout file's bytes. The archive contains source and build/install/maintenance integration, not private history. The old private GitHub repository is neither required nor recreated.

[baseline-verification.json](baseline-verification.json) records the fresh read-only checks: all 28 locally preserved assets matched the current Release API's SHA-256 digests and byte counts; all 371 source archive entries matched; 11 authoritative material index/overlay/installed-binding members matched their archive bytes and expanded copies. The materials index itself matched `CURRENT-MATERIALS-INDEX.json`. These checks read existing bytes and ZIP metadata; they did not build, launch, reinstall or run service probes. API digest agreement establishes byte correspondence, not publisher authentication. The five Chinese filenames use the unchanged transport-name mapping documented in the Release.

## Complete downstream coverage

[component-coverage.json](component-coverage.json) assigns every current index object by JSON pointer and selected identity/digest to the following tickets. Counts overlap by design: an artifact can contain many native files, and assets appear in both artifact and asset indexes. They are not a combined component or test total.

| Current materials index | Objects | Review owner and scope |
| --- | ---: | --- |
| `current/runtime-artifact-index.json` | 267 | [#3](https://github.com/yqia03/crosscript/issues/3): Python + 84 wheels; [#5](https://github.com/yqia03/crosscript/issues/5): 182 assets |
| `current/component-index.json` | 86 | #3: all component source/notice/build records, including Python, wheels and bootstrap pip; #4 also reviews their native members |
| `current/native-index.json` | 451 | [#4](https://github.com/yqia03/crosscript/issues/4): every native binary, its nested components, source/build/replacement provenance and notices |
| `current/asset-index.json` | 182 | #5: 34 fonts, 146 CMap JSON files, one model and one tiktoken data file |
| Own App, bridge, installer, build/maintenance integration | Within 371-file source manifest | #3: engine/source/build boundary; #4: native App/package identity where relevant |

The runtime selects 22 `bundle://` inputs (20 renamed fonts and two modified wheels) and 245 fixed HTTPS inputs. It does not select every historical object found in the materials archive. The current manifest/index digests above, together with the machine coverage file, fix exact versions and bytes; a package version string alone is insufficient. Distribution status and input delivery do not establish all downstream acceptance criteria.

In `Crosscript-third-party-materials-v4/`, use `CURRENT-INDEX.json` and `current/` for selection. Use `origin-materials/2026-10-26/` for retained sources and historical production evidence only. In particular:

- The 20 adopted font outputs and BabelDOC mapping changes are described by `current/fonts/DELIVERY-MANIFEST.json`; #5 covers font identity, glyph/metric and notice evidence, while #3 covers the modified BabelDOC wheel and integration. Original font bytes are not silently substituted for renamed selections.
- The selected GMP 6.3.0 and ZeroMQ 4.3.5 controlled library outputs remain adopted. `current/native-selected-inputs.json` binds `libgmp.10.dylib` (`ade1a64325a2418f4ea6143ab0914ba1eaf62496b307fd8e05b1a02cd460498c`) and `libzmq.5.dylib` (`3ec540381c648b832af9089faa54dfb292012bc6261ea82dcf7619236b629d35`). `current/native/manifest.json` contains source/configuration/notice references, including libsodium; #4 reviews those relationships.
- The selected OpenCV wheel is `opencv_python_headless-5.0.0.93-3crosscriptopenssl-cp37-abi3-macosx_14_0_arm64.whl`, SHA-256 `4f8048e641ec2a06c70e1e092cd4271ebd5cf94d9311b3125992dcc5efa8638d`. Its OpenSSL 3.6.0 libraries are `libcrypto.3.dylib` (`13aa519f1e6d13d3eb3968448e1166e5de03b70fa7b4ec5282e5c21318ab855e`) and `libssl.3.dylib` (`a2bdd0fd427991bdf846b87f1af9f697c6fae9f208accdb9dfad142b958b319d`). #4 uses `current/openssl/manifest.json` and provenance, not the old producer's unproven original build association.
- `current/native/` retains some records naming the earlier `2crosscriptnative` precursor wheel. That wheel and its original OpenSSL pair are excluded from the current distribution; retained GMP/ZeroMQ libraries plus the official upstream input and replacement recipe form the current rebuild path. The historical original OpenSSL production recipe has not been recovered or retroactively proven. That gap does not itself establish a license violation.
- `current/rav1e/delivery-manifest.json` and supplemental OpenCV records belong to #4. Preserve their qualified source/material scope; presence of a source archive is not proof of the original producer's exact build.

No component change is needed to establish this baseline. Existing adopted font/native/OpenSSL evidence is reused with its original scope; it is not represented as newly executed tests or blanket legal clearance. Own code remains AGPL-3.0-only, with third-party terms retained separately.

## App, data and credential identity

Metadata was read directly from the hash-matched preview ZIP, without launching the App or accessing Keychain.

| Boundary | Observed identity / compatibility rule |
| --- | --- |
| Product/release name | Crosscript; license/source links use this name |
| Signed display name | `CFBundleDisplayName = 翻译工作台`; localized App title is `翻译工作台` / `Translation Workbench` in source |
| Internal package/name/executable | `TranslationWorkbench.app` / `TranslationWorkbench` / `TranslationWorkbench` |
| Bundle ID and defaults domain | `dev.uown.translation-workbench` |
| App / platform | `0.1.0 (5)`, arm64, declared minimum macOS 14.2 |
| Default material root | `~/Library/Application Support/TranslationWorkbench/Recordings/`; explicit `--data-directory` overrides it |
| Material/configuration children | UUID recording folders, `TextWorkspace/`, retained legacy `TextMaterials/`, `PDFMaterials/`, `PDFRuntime/`; provider/audio configurations, task queue and shared translation resources stay under the material root |
| Text/PDF Keychain | service `TranslationWorkbench.TextPDFProviders`; account is SHA-256 of profile UUID + target scope |
| Audio/Gemini Keychain | service `TranslationWorkbench.OpenAIAudio`; official historical OpenAI account `api-key`; other service/address scopes use `api-key-<SHA-256>` |
| Signature | Ad-hoc integrity only; no Developer ID identity, notarization or stapling; no authenticated publisher continuity claim |

Crosscript branding has not renamed the persistence or Keychain scopes. Stable names preserve the intended compatibility boundary, but do not prove successful migration of every existing user's data or credential access under a changed ad-hoc signature. The signed source revision/archive digest match the identities above. No key value, actual user material, preference file or credential ACL was read or changed for this review.

Source contains bounded compatibility behavior and synthetic cases: `TextWorkspaceStore` retains/migrates `TextMaterials`; `RecordingStore` reads the legacy audio configuration; tests cover legacy recording workflow identity, audio configuration/history and Keychain target isolation (`TextWorkspaceMigrationTests`, `RecordingSessionTests`, `AudioProviderTests`, `PostRecordingIntegrationTests`). These test sources are available, **not a fresh build 5 compatibility pass**. The frozen build 5 test evidence explicitly excludes the full application suite. Real existing-data upgrade, actual Keychain prompts/authorization, ordinary-Mac installation/permissions and macOS 14.2 hardware remain unverified here. No cloud request was used to fill those gaps.

## Nonpublic recovery

A private recovery set was created and restored to a separate offline checkout during this task. [recovery-verification.json](recovery-verification.json) publishes only safe aggregate counts, archive digests and scope. The private archive, file manifest, Git index/status/refs, restore instructions and restored checkout contain private material and must never be committed or uploaded with public release evidence. The maintainer retains their location separately.

Recovery covers referenced private Git history and **3,655 current Git-visible / previously audited regular working files**, including dirty and untracked development materials (1,512,100,829 bytes). It excludes only this task's generated integration checkout from that file selection. Isolated restore reproduced all selected file bytes and modes with zero errors, preserved all saved Git refs in the bundle, and reproduced saved Git status after that explicit generated-checkout exclusion. The source checkout's status and HEAD were unchanged by archive/restore work.

Recovery method: verify the private archive digests; clone the bundle without network into a new private checkout; check out the saved private HEAD; overlay the saved working-file archive preserving modes; restore the saved Git index; compare each file with the private manifest and Git status with the saved status. The private `RESTORE.md` gives the exact procedure and the already verified restore directory. The deleted private remote is unnecessary.

This is **not a backup of every private asset on the Mac**. Other ignored build outputs/caches, external historical release evidence, other worktrees' dirty contents, orphan/reflog-only objects, Git config/hooks, xattrs, user recordings/application data and Keychain are outside the archive. The exact public source and 28 frozen assets remain separately recoverable from their release identities. External raw evidence was read in place, not copied into this private development recovery set. User-data backup/restore and Keychain migration have not been tested.

## Change and revalidation boundary

This evidence commit is additional documentation, not a replacement identity for the frozen release tree. Future changes must obtain a new source/tree/archive identity and, where applicable, App build/runtime/material identities. Never carry a former digest forward as evidence for different bytes.

| Changed surface | Required downstream review |
| --- | --- |
| App/bridge/installer/build sources or embedded source metadata | #3 source/build records; #7 source/distribution index; #8 new source/App/package binding; #9 separately scoped installation status; #10 public access |
| Python/wheels or engine | #3; native members #4; regenerate manifests/indexes/material/archive digests and redo affected runtime/package checks in #7–#10 |
| Fonts/model/CMap/tokenizer data | #5; font/BabelDOC integration #3; regenerate selected hashes and redo affected rendering/install/package checks |
| GMP/ZeroMQ/OpenSSL or other native bytes | #4 and affected #3 integration; redo precise source/config/output binding, signatures, load/compatibility and package checks; old runtime results do not transfer automatically |
| Bundle/data/Keychain identity | Explicit compatibility design and migration evidence; then affected source, documentation, package and installation reviews. A cosmetic product name is not authorization to rename storage scopes |

No paused PDF batch, live/paid probe, general quality sweep or new release was started. The four workflows and the ad-hoc, non-notarized preview scope remain as published.
