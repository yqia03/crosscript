# Asset provenance

## Current font derivatives

The 2026-10-27 candidate supplies 20 **Crosscript CJK Sans/Serif** TTFs covering CN, HK, JP, KR and TW in Regular/Bold. Their exact inputs are the previously pinned Source Han Sans 2.004 / Serif 2.003 conversions. The approved identity-only transformation changes all platform/language records for name IDs 1/3/4/6, filenames and required checksums; glyphs, cmap, metrics, GSUB/GPOS/GDEF and other non-identity table bytes are unchanged. Original copyright, reserved-name attribution, author, source and OFL notices remain intact.

The compact [font provenance index](../app/macos/Sources/TranslationWorkbench/Resources/PDF/Notices/ReleaseMaterials/CrosscriptFonts/provenance-index.json) binds each new SHA-256/SHA3-256 to the exact conversion ZIP/entry and Adobe fixed reference. [Modification notice and full licenses](../app/macos/Sources/TranslationWorkbench/Resources/PDF/Notices/ReleaseMaterials/CrosscriptFonts/README.md) accompany the App. Full editable scripts, mapping, patched BabelDOC source/wheel and evidence are in the companion's `current/fonts/`; original-identity converted TTFs and conversion ZIPs are not redistributed there.

Local focused tests compared 20 baseline/renamed pairs, 40 PDFs and 80 horizontal/true Identity-V pages with identical pixels and layout. HarfBuzz shaping via uharfbuzz also matched in horizontal/vertical directions. BabelDOC font mapping, actual CMap rewriting and missing/corrupt-cache handling passed offline. This covers the selected synthetic glyphs and current converted baseline, not every document, upstream OTF rendering equivalence or second-Mac acceptance. The other 14 font payloads, 146 CMaps, model and tokenizer remain pinned to their recorded original bytes.

## App icon

The current application icon was created for this project with the built-in image generation tool on 2026-10-20 and selected by the maintainer. It depicts two translation speech bubbles on a teal tile; the retained original is not imported third-party artwork or a user document. This provenance statement does not claim trademark clearance or exclusive rights over AI-generated artwork.

The original PNG, standard-size preview and ICNS container are retained under `app/macos/Resources`. `app/macos/scripts/build-app-icon.sh` uses macOS `sips` and `iconutil` to scale/package the original image. No private generation-session path is needed to rebuild the icon.

| File | SHA-256 |
| --- | --- |
| `AppIcon-generated.png` | `247df0adcd220ea337117b659f34e9b995590d0520ee34c988b73d48e7de0592` |
| `AppIcon-1024.png` | `3c8718f859ca6cdadf400204454daa4a96f71e4586b46ac10e497036ef566fe9` |
| `AppIcon.icns` | `87855da9e29c7aa4deac5180a8f22fa13e831da0176f71e56c8cd8000c7410fa` |
