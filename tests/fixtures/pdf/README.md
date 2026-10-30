# Original synthetic PDF fixture

`synthetic-one-page.pdf` is a 745-byte, one-page PDF generated for Crosscript release preparation on 2026-10-26. It contains only three short sentences written for the test, uses a standard PDF base font reference, and has no embedded font, author metadata, imported image or source document. It replaces a private historical fixture path; it does not carry the historical fixture's acceptance results.

Generator: `scripts/pdf/generate_synthetic_fixture.py` (Python standard library only). Both the original generator and this original synthetic material follow the project's AGPL-3.0-only choice; no new commercial-use restriction is added.

Reproduce to a new path from the source root:

```sh
python3 scripts/pdf/generate_synthetic_fixture.py NEW_OUTPUT.pdf
```

SHA-256: `02f4f326897d1e154b5d527bf6e6edf8eea1bfd657d41b5dad388a37697a30cd`.

The PDF structure and reproducibility can be checked offline. Real BabelDOC rendering/translation remains a separate bounded test requiring the exact prepared runtime; no such result is implied here.
