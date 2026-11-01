---
status: accepted
---

# Keep installation downloads separate from complete release materials

On 2026-11-01 the maintainer chose three manually uploaded assets for new releases: a drag-to-Applications DMG, an App ZIP, and one complete materials archive containing the exact source archive, third-party materials and validation records. The Release body puts the two installation choices first and provides their checksums; supporting records remain available inside the materials archive rather than as many individual downloads. This improves ordinary users' download choices while retaining version-specific source and evidence, at the cost of a larger combined download for recipients who need those materials.

Published build 5 and all its existing links remain unchanged. GitHub's automatically generated source downloads remain visible and do not replace the source archive bound to the signed App. New materials retain their original source/third-party archive filenames and bytes inside the combined archive. No standalone JSON, TXT, Markdown, scripts or checksum files are uploaded as additional Release assets.

The maintainer explicitly accepts the existing ad-hoc signature and first-open restrictions for this change. A DMG does not provide Developer ID identity or Apple notarization, and local packaging checks do not establish installation on another Mac. Application identity, data paths and runtime selection are unchanged.
