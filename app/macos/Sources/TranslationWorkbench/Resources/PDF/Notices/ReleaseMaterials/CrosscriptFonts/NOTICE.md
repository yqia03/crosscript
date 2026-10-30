# Crosscript CJK identity derivatives — modification notice

Modified on 2026-10-27 for the Crosscript preview candidate. These 20 files are
identity-only derivatives of the exact converted Source Han Sans 2.004 and Source
Han Serif 2.003 TTFs identified in `provenance-index.json`.

The new family names are **Crosscript CJK Sans** and **Crosscript CJK Serif**,
qualified by CN, HK, JP, KR or TW, and Regular or Bold weight. The filenames and
all platform/language records for OpenType name IDs 1, 3, 4 and 6 were changed.
The table directory checksums and required `head.checksumAdjustment` were
recalculated. The unique identifier records include `CrosscriptIdentity1`.
No new Reserved Font Names are declared by this modification notice.

All other name records remain byte-for-byte unchanged, including upstream
copyright, Reserved Font Name / trademark attribution, manufacturer, author,
license and source URLs. All non-identity table payloads, including outlines,
glyph order, cmap, metrics, GSUB, GPOS, GDEF, BASE, OS/2 and hinting-related tables,
remain byte-for-byte identical to the recorded converted TTF inputs, apart from
the checksum field above. This does not claim that the earlier CFF-to-TrueType
conversion was identical to Adobe's original OTF rendering.

The fonts remain under **SIL Open Font License 1.1**. The complete original
copyright and license texts accompany this delivery:

- `licenses/source-han-sans-OFL-1.1.txt`
- `licenses/source-han-serif-OFL-1.1.txt`

Upstream attribution to Adobe and the Reserved Font Name “Source” is retained
as required attribution. It is not used as the primary identity of these
derivatives and does not imply upstream endorsement. The exact Adobe source
references, conversion-release URLs, archive-entry hashes and resulting font
hashes are recorded per file in `provenance-index.json`.

The original-identity converted TTFs and conversion ZIPs are not redistributed
in this delivery. Their source identifiers and hashes allow reconstruction.
The deterministic identity transformation is provided in source form in
`tools/build_font_derivatives.py`, with `font-identity-map.json` as its exact
input specification. The renamed TTFs are in `derivatives/assets/fonts/`.

The BabelDOC 0.6.4 registry integration updates the exact 20 filenames, actual
embedded PDF names, SHA3-256 values, sizes and family references. Its local-font
guard requests runtime repair if a renamed file is absent or corrupt, before
any upstream download. The full modified Python sources and unified patches
are supplied in `derivatives/`; the wheel includes its own dated modification
notice and the unchanged upstream AGPL license. BabelDOC's package version
remains 0.6.4; the separate wheel build tag is `1crosscriptfonts`.

Crosscript's own integration and test scripts are licensed **AGPL-3.0-only**.
That choice does not relicense the fonts or impose extra restrictions on their
OFL permissions. Compliant commercial use is permitted under the applicable
licenses. This local preparation does not authorize public publication.
