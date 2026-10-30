# Crosscript source and build materials

Preparation status, 2026-10-29: this is the build 5 candidate, with approved App source-access links and controlled OpenSSL 3.6.0 replacement preparation. The confirmed destination is https://github.com/yqia03/crosscript. This candidate is not published; the links below become available only when the matching source and release are published. Final hashes and checks belong in RELEASE-BINDING.json. A missing page before publication is not a working download.

Crosscript's own code is licensed under AGPL-3.0-only. The release must provide this project's exact source, integration modifications, necessary build/install scripts, and the applicable third-party source and notice materials together with the matching preview. See [distribution materials](distribution-materials.md), [third-party notices](../THIRD_PARTY_NOTICES.md) and [release gates](release-preparation.md). A version label alone does not bind an executable to its source.

## Confirmed publication destination (available after publication)

- Project: https://github.com/yqia03/crosscript
- Matching source tree: https://github.com/yqia03/crosscript/tree/v0.1.0-preview.5
- Own-code license: https://github.com/yqia03/crosscript/blob/v0.1.0-preview.5/LICENSE
- Third-party notices: https://github.com/yqia03/crosscript/blob/v0.1.0-preview.5/THIRD_PARTY_NOTICES.md
- Matching preview, exact source archive, complete third-party materials and checksums: https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5

中文：已确认公开目标为 yqia03/crosscript，本候选使用 build 5 与 v0.1.0-preview.5。源码、许可、第三方说明及材料入口如上；链接待对应版本公开发布后生效，未发布时可能显示未找到。自有代码 AGPL-3.0-only，第三方保留各自许可；完整文本和组件通知也随 App 本地提供。

The App license window provides these same versioned links and the full bundled texts. The exact build-source identifier and source archive digest are embedded in the signed Info.plist. A new public root commit may have a different commit ID; its reviewed tree and file manifest must match the build input, with the relationship recorded publicly. Do not substitute a moving main branch or another build for this version.

Build with an Apple Silicon Mac, a Swift 6 toolchain and the macOS SDK. From the source root, select a fresh independent output path:

```sh
WORKBENCH_SIGNING_IDENTITY=- WORKBENCH_SIGNING_KEYCHAIN='' \
  WORKBENCH_APP_BUNDLE="$PWD/output/local-preview/TranslationWorkbench.app" \
  bash app/macos/scripts/build-app.sh release
```

This explicitly selects ad-hoc integrity signing. Developer ID signing, notarization and stapling are not performed or required for this preview plan. Ad-hoc signing does not authenticate the publisher. Keep the internal bundle identifier and data/keychain names stable to avoid breaking existing local data.

The pinned PDF environment is installed by the app on first use; a packaged preview does not require a separate development Python. The current runtime is `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`. Its [manifest](../app/macos/Sources/TranslationWorkbench/Resources/PDF/runtime-manifest.json) has 22 `bundle://pdf/Bundled/` inputs (20 renamed fonts and two modified wheels) and 245 unchanged HTTPS inputs. The installer validates the selected bytes in both paths. [bundled-runtime-index.json](../app/macos/Sources/TranslationWorkbench/Resources/PDF/bundled-runtime-index.json) records the replacements; [upstream-runtime-manifest.json](../scripts/pdf/pins/upstream-runtime-manifest.json) is the old origin pin, not the current install target. Public upstream URLs and hashes do not replace corresponding-source delivery. [PDF maintenance instructions](pdf-maintenance.md) explain the retained maintenance tools.

Before public distribution, verify the confirmed versioned URLs anonymously, publish the matching source and complete materials together, and bind the public tree/revision to the signed App source metadata and archive digest. Do not mark these links accessible until checked. Final metadata and legal text must be written before signing, with no post-sign edits.

中文：本文件仍是本地发布准备说明。公开前必须补实际匹配的源码、修改、构建/安装脚本和第三方材料取得方式，并与预览包同时交付。许可证选择已经确定，但本文件不表示来源绑定、分发材料或另一台 Mac 安装已经通过。

## Matching local companion files

- `Crosscript-source-0.1.0-5.tar.gz`: the clean source snapshot for this candidate, including build/install/maintenance scripts, bundled modified inputs and synthetic tests.
- `Crosscript-third-party-0.1.0-5-materials-v4.tar.gz`: full source/notice materials and current provenance indexes, including the editable font/BabelDOC changes and controlled GMP/ZeroMQ/OpenSSL build recipes. Source presence and proof of a particular original build are recorded separately.
- `RELEASE-BINDING.json` and `SHA256SUMS.txt`: source revision, archive digests, toolchain and build/package relationships.
- `Crosscript-preview-0.1.0-5.zip`, `APP-MANIFEST.tsv` and `verify-preview-app.sh`: the planned matching preview and integrity check materials.

The final signed App must include `CrosscriptSourceRevision` and `CrosscriptSourceArchiveSHA256` in Info.plist. `scripts/release/build-bound-candidate.py` creates the source archive, enforces a clean source tree and fresh external Swift build directory, uses a restricted environment and denies build-process network access. Metadata must be final before signing; verify strict signatures and package hashes afterward. The build script removes development bytecode/metadata from inputs and strips only executable debug-map symbols before ad-hoc signing. These steps do not close human publication review or second-Mac installation gates.

In the materials archive, `Crosscript-third-party-materials-v4/CURRENT-INDEX.json` is authoritative for this runtime; `current/` contains the current artifact, asset, native and component indexes. `current/fonts/` supplies editable BabelDOC changes, font identity mapping, original licenses and focused offline evidence. `current/native/` supplies exact GMP 6.3.0, ZeroMQ 4.3.5 and libsodium source inputs, build configuration, notices and replacement instructions. `current/openssl/` supplies the exact OpenSSL 3.6.0 source, configuration, commands, output hashes, compatibility checks and replacement/repack instructions. `origin-materials/` preserves previous source/build evidence and is not a claim that every old binary is still selected. Install-time verification must distinguish modified wheel build tags and installed-file hashes, not just the unchanged package versions.

For a comparable local build from a clean Git checkout, run `python3 -B scripts/release/build-bound-candidate.py --source "$PWD" --output /path/to/new-independent-output`. From the source archive alone, the ordinary build command above builds the source, while `RELEASE-BINDING.json` identifies its original revision and archive hash. Do not reuse an existing release App output.
