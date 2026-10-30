# Preview release acceptance gates

The planned first release is Crosscript 0.1.0 preview with all four workflows: text/Markdown, PDF translation, recording with post-recording transcription, and live bilingual captions. Own code remains AGPL-3.0-only; compliant commercial use is allowed. Third-party licenses remain unchanged.

The preview uses ad-hoc signing and is not Developer ID signed, notarized or stapled. Apple Developer Program enrollment is not a prerequisite. Minimum macOS 14.2 remains a declared target with validation on that exact OS still deferred.

Build 5 selects runtime `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3`: 20 identity-renamed fonts, a matching BabelDOC registry wheel and a controlled GMP/ZeroMQ/OpenSSL replacement wheel are bundled; the other 245 artifact URLs remain HTTPS pins. The approved font and native changes have exact provenance, original notices and focused offline evidence. Their previous identity/original-build gaps are addressed by these new derivatives/builds, not by claiming new permission for the old binaries. The complete current companion is `Crosscript-third-party-0.1.0-5-materials-v4.tar.gz`; its indexes distinguish source collected from build association verified.

This source snapshot is a review proposal. It must not be described as an approved or published release. The following independent gates remain:

- Review the exact public files, resource provenance and synthetic fixtures; exclude credentials, personal materials, machine metadata and private history.
- Review the [current third-party source, build and notice delivery](distribution-materials.md), its exact indexes and recipient access arrangements for the selected bytes. Do not infer all-component approval from collected sources; use the current evidence for the implemented font/GMP/ZeroMQ/OpenSSL changes.
- Freeze the reviewed source and record its exact content manifest, toolchain, version, build inputs and appropriate scoped regression results. Bind the source archive to the final App and ZIP.
- Verify ad-hoc integrity, arm64 architecture, metadata, entitlements, complete package trees, extraction round trip and published checksums. A packaging check is not release completion.
- On a separate ordinary Apple Silicon Mac, verify a real browser download with quarantine preserved, normal installation, first launch, the applicable per-app Open Anyway flow, permissions, first PDF preparation, history and export. Do not disable global security, remove quarantine or locally re-sign to make acceptance pass.
- Provide accurate limitations and distinguish not run, failed and passed results. Live/paid provider testing is separate from local acceptance and requires its own explicit authorization; stopped service tests are not part of this preparation.
- After review and explicit publication approval, release source, applicable third-party materials, preview ZIP, App manifest and SHA-256 values together in the new public repository. Preserve the existing private development archive without copying its history into the new repository.

Feedback and vulnerability-report destinations will be added when the reviewed public repository exists. Do not post credentials or private samples. See [testing scope](testing.md) and [source/build status](source-and-build.md).

The confirmed repository is https://github.com/yqia03/crosscript. Build 5 uses tag v0.1.0-preview.5; versioned source/license/material links are visible in the App with a publication-pending notice. They must be checked after publication. The build 4 second-Mac gate was accepted per the user statement without independent logs; it does not cover the new OpenSSL libraries or App in build 5. The new candidate requires a focused second-Mac recheck and final publication authorization.
