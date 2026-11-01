# Build 6: DMG and three release downloads

Published on 2026-11-01 (Asia/Hong_Kong): [v0.1.0-preview.6](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.6), tracked in [#11](https://github.com/yqia03/crosscript/issues/11).

- Source and tag: `2ec554556c8dd8f4ec022352b6064f4c0987737f`.
- Exact source archive SHA-256: `981817ff9bf0f8ea76eb5a9e6dbf6428b27ab113c13974429e520bc0cbcbd2fe`, recorded in the signed App and included under `source/` in complete materials.
- Same App in DMG and ZIP: tree SHA-256 `8ef2e7c8c5d3dbcf6069015efdd5b2f16b1fbcc75a14106d92aa8ab923dc0bec` (paths, file bytes, modes and directories; extended attributes excluded).
- Passed: clean-source isolated build and provenance binding; 26 package tests and 18 assembly tests; actual DMG create/verify/readonly mount/copy/strict ad-hoc checks/detach; independent ZIP extraction and full-payload comparison; complete-materials streaming verification of all 20 members and internal checksums.
- Uploaded assets: exactly `Crosscript-preview-0.1.0-6.dmg`, `Crosscript-preview-0.1.0-6.zip`, `Crosscript-materials-0.1.0-6.tar.gz`. GitHub-generated source downloads are separate. The Release body supplies the outer checksums; the materials include original source/third-party archives, evidence and internal checksums.
- Build 5: its Release body and all 28 asset IDs, names, sizes and digests were compared with the pre-change snapshot and remain unchanged.

[Public delivery record](public-delivery.json) and [complete-materials roundtrip](materials-roundtrip.json) record final delivery checks. The supplied archive's `evidence/RELEASE-BINDING.json`, `build-binding.json`, `dmg/preview.json` and `zip/preview.json` retain build and package details. Per-tool preparation/publication flags record their local execution stage; they do not override this release's actual public state.

No Developer ID signing, notarization, Gatekeeper acceptance, second-Mac installation, macOS 14.2 hardware check, fresh cloud-service acceptance or full-product regression was performed. Build 5's waiver does not become a build 6 passing test. App behavior, identity, data/Keychain paths and PDF runtime inputs are unchanged; the App source diff from build 5 consists of the build number and versioned license-window links. Historical runtime/material records remain historical.

This post-publication documentation does not alter the tag, signed App, exact source archive or uploaded assets. The reproducible source for this release is the pinned tag/source archive, not the later moving main branch.
