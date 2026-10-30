# Changes made for the proposed public source snapshot

Initial file selection: 2026-10-26 (historical baseline). The application source, four workflows, existing runtime pins and selected licenses were unchanged by that initial file-selection step. This is a local proposal; public release remains subject to the independent gates in [release preparation](release-preparation.md).

- Selected the native source tree, both SwiftPM test targets, required resources, build/signing scripts, PDF maintenance and controlled test code, preview packaging tools and their offline boundary tests. Development caches, private historical logs, unknown-rights samples, live-service acceptance probes and old repository history are not included.
- Replaced internal-history links in public documentation with maintained public-facing preparation pages. Kept explicit not-published and incomplete-source-delivery statements.
- Retained two metadata pins unchanged under `scripts/pdf/pins`. Maintenance generators now accept explicit input and fresh output locations. Their algorithms retain the same dependency selection and source-inventory purpose; they are not proof of corresponding-source completeness.
- Added an original deterministic synthetic one-page PDF and its standard-library generator. Controlled PDF tests reference this fixture instead of a private historical document; the direct engine probe uses the same generator instead of a ReportLab-only sample generator. The runtime cache must be supplied explicitly. These source changes do not claim a successful engine run.
- Recorded the existing AI-generated icon's provenance and hashes without a private generation-session path. Retained upstream copyright/license texts byte-for-byte.
- Added ignore entries for temporary files, caches and local credentials. This file-selection step does not strip or rewrite a downloaded application, clear quarantine or weaken macOS security.

Subsequent release-tool, version-metadata or source/material-index changes must be recorded by the final build and release binding. Regenerate the final source manifest after those edits; this preparation note does not identify a final binary revision.

## Release preparation refinements

The preserved earlier local candidate used build number 3. Release scripts require a fresh App output, expose an independent Swift build directory, use controlled build environment/toolchain recording, omit development caches, strip executable debug-map symbols before signing, and embed source revision/archive SHA in the signed Info.plist. Source paths are remapped for build artifacts. Preview tools reject cache/AppleDouble inputs and omit resource metadata in the ZIP while leaving the original input untouched; normal browser quarantine remains an installation observation. Full fixed asset/GPL-family notices and the encoding-data license-scope evidence are included. At that earlier stage, application Swift/PDF bridge code and production runtime pins were unchanged. The current build 4 changes below supersede that statement for the new candidate.

## Approved build 4 preparation (2026-10-27)

- Preserve the original workspace and build 3. Use a new isolated source candidate with the same four workflows, own AGPL-3.0-only license and ad-hoc, non-notarized preview route.
- Select `babeldoc-0.6.4-py312-20261027-arm64-crosscript-v2`: 20 Crosscript CJK fonts plus BabelDOC `1crosscriptfonts` and OpenCV `2crosscriptnative` wheels are bundled; 245 HTTPS inputs remain pinned. Retain the original full runtime manifest as `scripts/pdf/pins/upstream-runtime-manifest.json` for provenance. Historical dependency/asset pins are upstream inputs, not the current install manifest.
- Rename only the approved font identity records and required checksums, preserving every other table/attribution record. Update BabelDOC's exact font names/SHA3/family mappings and fail locally on missing/corrupt custom fonts. Ship complete original OFL and modification notices.
- Replace only GMP 6.3.0 and ZeroMQ 4.3.5 inside OpenCV with controlled local builds. Preserve other payload bytes, record exact sources/configuration, include LGPL/MPL and other applicable notices, and retain the SO_BINDTODEVICE compatibility configuration.
- Add the minimal bundled-input installer path with the same digest validation, cancellation and isolated-cache protections used for downloads. Source/install/runtime inventories identify the selected bytes; this note does not replace the focused test records or final build binding.
- Update current source/materials/asset notices and metadata to distinguish collected source from proven build association. The companion is `Crosscript-third-party-0.1.0-4-materials-v3.tar.gz`, whose `CURRENT-INDEX.json` and `current/` records supersede historical origin status fields.

Font-table checks, bounded 20-font PDF rendering/mapping regression and native ABI/offline checks passed in their isolated preparation scopes. They do not establish full application/service coverage, minimum-OS hardware acceptance, another-Mac installation or publication approval. Final source/archive metadata must be frozen before signing; final App/ZIP hashes and signature checks belong in the build 4 release binding.

## Approved build 5 preparation (2026-10-29)

Build 4 remains immutable. Build 5 adds visible, versioned repository/source/license/third-party/release links in the App license window, marked available after publication. The confirmed target is yqia03/crosscript and the new tag is v0.1.0-preview.5. The complete own-code license and third-party notices remain local and readable.

The approved controlled same-version OpenSSL 3.6.0 rebuild replaces only libcrypto.3.dylib and libssl.3.dylib in the existing modified OpenCV wheel; approved GMP/ZeroMQ and font changes are retained. The new runtime ID is babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3. Exact outputs and scoped checks must appear in the new binding/materials-v4 records before this candidate is sealed. This does not prove the old original producer recipe or transfer build 4 acceptance to new bytes. No public release, push, upload or stopped live/paid probes are part of this preparation.
