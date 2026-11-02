# Crosscript source and build materials — 0.1.0 (7)

This document describes the published build 7 preview and its version-specific source/material links. Earlier releases and their original files remain unchanged. The signed App records exact source revision `4579cac20caafdd4dc716def209cb21b8b100a66` and source archive SHA-256 `9715aa1dd0825123e3f4a07685c653238f6a04de9cb93de8088535c275d2579a`. The complete materials archive supplies that exact build input; later evidence and download-guide commits do not change it.

- Project: https://github.com/yqia03/crosscript
- Matching source: https://github.com/yqia03/crosscript/tree/v0.1.0-preview.7
- Own-code license: https://github.com/yqia03/crosscript/blob/v0.1.0-preview.7/LICENSE
- Third-party notices: https://github.com/yqia03/crosscript/blob/v0.1.0-preview.7/THIRD_PARTY_NOTICES.md
- DMG, App ZIP and complete materials: https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.7

Crosscript's own code is AGPL-3.0-only; third-party components retain their own terms. The complete materials archive supplies the exact project source, integration changes, build/install/maintenance scripts, applicable third-party sources/notices and verification records. See [distribution materials](distribution-materials.md) and [third-party notices](../THIRD_PARTY_NOTICES.md). A version label or GitHub-generated source ZIP does not replace the App-bound source archive.

中文：这是已公开发布的 build 7 预览版。普通用户选择 DMG 或 App ZIP 安装即可，无需下载完整材料。需要源码、第三方材料及验证记录时，下载同版 `Crosscript-materials-0.1.0-7.tar.gz`。App 签名内记录上述精确源码版本与归档摘要，后续证据与下载说明提交不改变构建输入；自有代码为 AGPL-3.0-only，第三方保留各自许可，完整许可文本也随 App 离线提供。

## Complete materials layout

The complete materials archive has root `Crosscript-materials-0.1.0-7/`:

- `source/Crosscript-source-0.1.0-7.tar.gz`: the exact clean committed source snapshot used for this App.
- `third-party/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz`: the unchanged complete companion for the unchanged PDF runtime. Its original filename and historical records remain intact; inclusion in build 7 does not claim that its historical tests were rerun.
- `evidence/`: build 7's source/build binding, App/package verification and actual test results, plus the record explaining runtime/material reuse.
- `manifest.json`, `SHA256SUMS.txt` and `README.md`: archive contents, digests and directions.

The matching Release body links the three downloads and displays their SHA-256 values. Individual JSON, scripts, Markdown and checksum files are kept in the materials archive rather than uploaded as extra assets. The build 5 tag, source, App, downloads and historical documentation remain available unchanged at [its original release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5).

## Build from source

Use Apple Silicon, Swift 6 and the macOS SDK. From the source root, select a fresh output path:

```sh
WORKBENCH_SIGNING_IDENTITY=- WORKBENCH_SIGNING_KEYCHAIN='' \
  WORKBENCH_APP_BUNDLE="$PWD/output/local-preview/Crosscript.app" \
  bash app/macos/scripts/build-app.sh release
```

For a source-bound candidate from a clean Git checkout:

```sh
python3 -B scripts/release/build-bound-candidate.py \
  --source "$PWD" --output /path/to/new-independent-output
```

The driver archives tracked inputs, records the toolchain, restricts the build environment, denies build-process network access and embeds source identifiers before signing. It checks that source files remain unchanged. The ordinary build command also works from an extracted source archive but does not embed source identifiers by default; the original distribution's identifiers are in its companion build binding. Do not reuse an existing Release output or edit a signed App.

The preview uses ad-hoc integrity signing. Developer ID signing, notarization and stapling are not performed; the maintainer accepts the existing first-open restrictions for this packaging change. The DMG adds drag-to-Applications installation, not publisher authentication. Bundle identity, data paths and Keychain names stay unchanged. Package and signature verification do not establish another-Mac, minimum-OS, Gatekeeper or cloud-workflow acceptance; build 5's installation waiver is a historical record, not a passing result for build 7.

[Build 7 verification](release-verification/build7/README.md) records 62 passing tests, native Finder layout and remount checks, ZIP/DMG App consistency, and a local Finder Copy/Paste installation into `/Applications/Crosscript.app` with an isolated synthetic-data launch and cleanup. A later [actual Finder drag check](release-verification/build7/drag-install.json) also passed: the installed copy matched the full App tree and strict signature, launched with isolated synthetic legacy data, quit normally and was cleaned up; the old App remained unchanged. These checks used the build Mac; ordinary-Mac installation, Gatekeeper, real Keychain/TCC migration and cloud workflows remain untested. The App name and executable are **Crosscript**; compatibility identifiers and stored data remain unchanged.

See [release packaging](release-packaging.md) for DMG/ZIP roundtrip checks and the three-asset assembly command. The published files are bound to the source and material digests recorded for build 7.

## Unchanged PDF runtime and companion

The pinned PDF environment is installed by the app on first use; a packaged preview does not require a separate development Python. The current runtime is `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`. Its [manifest](../app/macos/Sources/TranslationWorkbench/Resources/PDF/runtime-manifest.json) has 22 `bundle://pdf/Bundled/` inputs (20 renamed fonts and two modified wheels) and 245 unchanged HTTPS inputs. The installer validates the selected bytes in both paths. [bundled-runtime-index.json](../app/macos/Sources/TranslationWorkbench/Resources/PDF/bundled-runtime-index.json) records the replacements; [upstream-runtime-manifest.json](../scripts/pdf/pins/upstream-runtime-manifest.json) is the old origin pin, not the current install target. Public upstream URLs and hashes do not replace corresponding-source delivery. [PDF maintenance instructions](pdf-maintenance.md) explain the retained maintenance tools.

Inside the preserved third-party companion archive, `Crosscript-third-party-materials-v4/CURRENT-INDEX.json` is authoritative for this runtime; `current/` contains the current artifact, asset, native and component indexes. `current/fonts/` supplies editable BabelDOC changes, font identity mapping, original licenses and focused offline evidence. `current/native/` supplies exact GMP 6.3.0, ZeroMQ 4.3.5 and libsodium source inputs, build configuration, notices and replacement instructions. `current/openssl/` supplies the exact OpenSSL 3.6.0 source, configuration, commands, output hashes, compatibility checks and replacement/repack instructions. `origin-materials/` preserves previous source/build evidence and is not a claim that every old binary is still selected. Install-time verification must distinguish modified wheel build tags and installed-file hashes, not just the unchanged package versions.
