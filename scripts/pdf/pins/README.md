# Retained maintenance pins

These two metadata files support the retained maintenance algorithms; they are not user documents or runtime caches.

- `assets-manifest.json`: the upstream-derived BabelDOC asset filename and SHA3-256 pin inventory used to establish the app's current SHA-256 runtime asset pins. Asset bytes are not included; obtain exact matching bytes via the locked runtime manifest and verify them before maintenance.
- `upstream-capabilities.json`: BabelDOC 0.6.4 source AST inventory, identified by upstream commit `17480db9df92ddcb37349ce34b312335226e8ec9`. It enumerates 77 CLI options and 56 direct API parameters. Parameter help/default metadata retain their upstream provenance.

Upstream source: https://github.com/funstory-ai/BabelDOC/tree/v0.6.4 . Its AGPL license text is retained in the PDF notice directory. These files were relocated without changing bytes for the proposed public snapshot. They are maintenance evidence, not release acceptance or complete native dependency corresponding source.
