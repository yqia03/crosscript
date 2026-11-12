# Crosscript source and build materials — 0.1.0 (8)

This document describes Crosscript **0.1.0 (8)**, with selected release tag `v0.1.0-preview.8`. Its source and downloads are available at the destinations below. The previous [build 7 preview](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.7), its tag, source and downloads retain their original identities; its source and carrier hashes do not identify build 8.

For a source-bound App, the exact build-input commit and source archive SHA-256 are recorded in the signed `Crosscript.app/Contents/Info.plist` keys `CrosscriptSourceRevision` and `CrosscriptSourceArchiveSHA256`. The license window displays those values. Compare them with `evidence/build-binding.json` and the source archive in the matching complete materials. The document is itself a build input, so it does not hardcode its own source archive hash. Builds made without source binding may omit these keys and do not inherit another App's identifiers.

- Project: https://github.com/yqia03/crosscript
- Matching source: https://github.com/yqia03/crosscript/tree/v0.1.0-preview.8
- Own-code license: https://github.com/yqia03/crosscript/blob/v0.1.0-preview.8/LICENSE
- Third-party notices: https://github.com/yqia03/crosscript/blob/v0.1.0-preview.8/THIRD_PARTY_NOTICES.md
- DMG, App ZIP and complete materials: https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.8

Crosscript's own code is AGPL-3.0-only; third-party components retain their own terms. The matching complete materials must supply the exact project source, integration changes, build/install/maintenance scripts, applicable third-party sources/notices and verification records. See [distribution materials](distribution-materials.md) and [third-party notices](../THIRD_PARTY_NOTICES.md). A version label or GitHub-generated source ZIP does not replace the App-bound source archive.

中文：本文对应 `0.1.0 (8)` 预览版，选定标签为 `v0.1.0-preview.8`；源码与下载可从上述同版地址取得。精确构建源码和源码归档 SHA-256 以签名内 `Info.plist` 的 `CrosscriptSourceRevision`、`CrosscriptSourceArchiveSHA256` 为准，许可证窗口会显示它们；请与同版材料的 `evidence/build-binding.json` 及源码归档核对。本文本身属于构建输入，不硬编码自身归档摘要。已发布 preview.7 及 candidate06 的标识和历史证据保持原样，不得当作 build 8 的标识或测试结果。

## Complete materials layout

The matching complete materials archive has root `Crosscript-materials-0.1.0-8/`:

- `source/Crosscript-source-0.1.0-8.tar.gz`: the exact clean committed source snapshot used for this App.
- `third-party/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz`: the existing complete companion for the unchanged PDF runtime. Retain its original filename and historical records; reuse does not mean its historical tests were rerun.
- `evidence/`: build 8's source/build binding and package verification, supplied test results, and the record explaining runtime/material reuse. Historical checks must retain their original candidate identity and scope.
- `manifest.json`, `SHA256SUMS.txt` and `README.md`: archive contents, digests and directions.

The [matching Release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.8) provides `Crosscript-preview-0.1.0-8.dmg`, `Crosscript-preview-0.1.0-8.zip` and `Crosscript-materials-0.1.0-8.tar.gz`, with SHA-256 values in its body. Individual JSON, scripts, Markdown and checksum files belong in the materials archive rather than extra uploaded assets.

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

The preview uses ad-hoc integrity signing. Developer ID signing, notarization and stapling are not performed. Bundle identity, data paths and Keychain names stay unchanged. Package and signature verification do not establish ordinary-Mac, minimum-OS, Gatekeeper or cloud-workflow acceptance. Historical [build 7 verification](release-verification/build7/README.md) and [candidate06 acceptance](release-verification/post34-20261104/acceptance.md) describe their original App bytes and scoped results; neither is a build 8 result. Consult the matching materials for build 8 source/build binding, package checks and affected-scope verification. See [release packaging](release-packaging.md) for DMG/ZIP roundtrip checks and three-asset assembly.

## Unchanged PDF runtime and companion

The pinned PDF environment is installed by the app on first use; a packaged preview does not require a separate development Python. The current runtime is `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`. Its [manifest](../app/macos/Sources/TranslationWorkbench/Resources/PDF/runtime-manifest.json) has 22 `bundle://pdf/Bundled/` inputs (20 renamed fonts and two modified wheels) and 245 unchanged HTTPS inputs. The installer validates the selected bytes in both paths. [bundled-runtime-index.json](../app/macos/Sources/TranslationWorkbench/Resources/PDF/bundled-runtime-index.json) records the replacements; [upstream-runtime-manifest.json](../scripts/pdf/pins/upstream-runtime-manifest.json) is the old origin pin, not the current install target. Public upstream URLs and hashes do not replace corresponding-source delivery. [PDF maintenance instructions](pdf-maintenance.md) explain the retained maintenance tools.

Inside the preserved third-party companion archive, `Crosscript-third-party-materials-v4/CURRENT-INDEX.json` is authoritative for this runtime; `current/` contains the current artifact, asset, native and component indexes. `current/fonts/` supplies editable BabelDOC changes, font identity mapping, original licenses and focused offline evidence. `current/native/` supplies exact GMP 6.3.0, ZeroMQ 4.3.5 and libsodium source inputs, build configuration, notices and replacement instructions. `current/openssl/` supplies the exact OpenSSL 3.6.0 source, configuration, commands, output hashes, compatibility checks and replacement/repack instructions. `origin-materials/` preserves previous source/build evidence and is not a claim that every old binary is still selected. Install-time verification must distinguish modified wheel build tags and installed-file hashes, not just the unchanged package versions.
