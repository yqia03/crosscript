# Build the three release downloads

New releases provide **DMG**, **App ZIP**, and **complete materials**. The DMG is the recommended installation choice: open it in Finder, drag `Crosscript.app` to `Applications`, eject the image, then open the installed app. The ZIP contains the same App and is an alternative, not an additional required download. Both use the current ad-hoc signature; neither is notarized.

中文：普通用户下载 DMG 或 App ZIP 其中之一即可。DMG 打开后将 `Crosscript.app` 拖入 `Applications`，推出磁盘映像，再从应用程序目录打开。完整材料包供需要源码、第三方材料或验证记录的用户下载，不是运行 App 的必需步骤。

The three-download policy first applied in build 6. The existing [build 5 release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5) and build 6 release, their tags and their assets are preserved. The Finder presentation described below applies only to later builds; it does not change or repackage those historical downloads. GitHub's two automatic source links are outside the uploaded-asset count.

## Prepare a fresh candidate

1. Commit the final source, version/build, matching license-window release tag and bundled legal/source instructions. Do not modify an App after signing.
2. Run `python3 -B scripts/release/build-bound-candidate.py --source "$PWD" --output /path/to/new-candidate` from a clean checkout. Its exact source archive and build metadata must match the signed App.
3. Package the same App twice using `scripts/release/package-preview.py`, once with `package` and once with `package-dmg`. Each stage needs a separate new output directory; pass `--app`, `--source`, `--source-root`, `--notice-root`, `--version`, `--build` and `--output`. The source SHA is the candidate's build-input commit, not a later documentation commit.
4. Verify the App's selected runtime against the third-party companion. When the runtime is unchanged, the existing exact companion archive can be included without renaming its internal records or claiming new component tests. Record which build supplied it and why it applies.
5. Collect build binding, source manifest, ZIP/DMG packaging reports, focused test results and actual installation results in a new evidence directory. Preserve historical records as historical; do not convert `not-run` into passing results.

## Assemble only the public downloads

```sh
python3 -B scripts/release/assemble-release.py \
  --dmg /path/to/dmg/Crosscript-preview-0.1.0-7.dmg \
  --zip /path/to/zip/Crosscript-preview-0.1.0-7.zip \
  --source-archive /path/to/candidate/Crosscript-source-0.1.0-7.tar.gz \
  --third-party-archive /path/to/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz \
  --evidence-dir /path/to/evidence \
  --source-commit FULL_BUILD_INPUT_SHA \
  --version 0.1.0 --build 7 \
  --output /path/to/new-release
```

Only the three files in the generated `assets/` directory are uploaded. `RELEASE.md`, `release-manifest.json` and the outer checksum file remain local; the Release body displays checksums and links to complete materials. The materials archive preserves the exact source under `source/`, the third-party archive under `third-party/`, and records under `evidence/`, with an internal manifest and checksums. Each uploaded file must be smaller than GitHub's 2 GiB asset limit; exceeding it fails assembly rather than silently adding another asset.

Upload to a **new** version/tag; never use an overwrite flag or modify build 5. Verify the remote release has exactly the three expected uploaded names, sizes and digests, plus working download links. The generated source links are not an installation option. A release publication does not change recorded test outcomes.

## Finder presentation for builds after build 6

`package-dmg` builds a writable HFS+ image, mounts that new image at a private output path, generates its Finder metadata without launching Finder, detaches it, and converts it to the final compressed read-only UDZO image. It then verifies and mounts that final image read-only, compares the complete payload tree, copies the App out, and checks its complete tree and strict ad-hoc signature. The input App is never renamed, edited or re-signed by packaging.

The default Finder content area is 640 × 400 points, with 112-point App and Applications icons at `(150, 180)` and `(490, 180)`. A native Swift/AppKit script draws a pale blue, mint and yellow background, a looped directional arrow, and Chinese/English drag instructions. The TIFF contains 640 × 400 and 1280 × 800 representations for standard and Retina displays. The background contains no imitation application or folder icons: both visible items are real Finder objects, and Applications links exactly to `/Applications`.

A headless Python script writes icon view, manually positioned icons, hidden toolbar/status/path/tab bars, and a collapsed sidebar into the image's root `.DS_Store`. Window dimensions and hidden-bar settings are saved opening defaults; users can resize Finder, and Finder may preserve a user’s global path/status-bar preferences when opening a new image window. The guide text stays inside the top 340 content points (Chinese at y=300, English at y=324), so both lines remain visible when those bars reduce the available content height. Visual acceptance checks the actual background, icons and complete instructions; it does not claim the bars are unconditionally hidden. The background alias is created from the actual background file inside the mounted image, preserving the HFS+ volume name/creation identity and file/directory CNIDs. Its target path is relative to that volume (`/.background/installer.tiff`); the temporary build mount path is replaced with the portable canonical `/Volumes/Crosscript Preview` volume reference. The script reads back the generated records and uses the native CoreFoundation resolver, with UI and mounting disabled, to prove that the alias resolves to the image file rather than a parent folder. It repeats these checks after the final image is mounted at a different path. Only the DMG root may contain `.DS_Store`; metadata remains forbidden inside the signed App and throughout the App ZIP.

The root installation surface shows only the App and Applications. External `LICENSE`, `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md`, `APP-MANIFEST.tsv`, `PREVIEW.txt`, `INSTALL.txt` and layout settings remain in the image's hidden `.release-info` directory. To read them, press **Command-Shift-G** in Finder and enter the mounted image path followed by `/.release-info`; **Command-Shift-.** also reveals hidden items. Legal materials remain available from the App's license window and the complete materials download. The ZIP retains its visible external attachments.

This stage needs the existing macOS Python, `swift`/AppKit and `hdiutil` tools. Pinned, unmodified `ds_store` 1.3.3 and `mac_alias` 2.2.3 Python sources are retained under `scripts/release/vendor` with their original MIT licenses, exact distribution hashes and per-file provenance. These are build-time tools, are not copied into the App/image, require no global installation, and add no consumer dependency. Upstream [dmgbuild documentation](https://dmgbuild.readthedocs.io/en/latest/) describes the same direct-metadata approach; its [official implementation](https://github.com/dmgbuild/dmgbuild/blob/main/src/dmgbuild/core.py) creates an alias from the mounted background before writing the Finder records.

The build process needs permission to create/mount disk images; it does not require an interactive GUI session, Finder, Automation, Accessibility, or access to user Finder preferences. Layout generation and verification each have a 30-second timeout. A missing background/layout, invalid volume-relative alias, changed payload or failed unmount fails packaging and cannot produce a successful `preview.json`. Both writable and final verification mounts are cleaned up on errors, with a force-detach retry (each detach command has a 20-second timeout); inspect the recorded mount path if both detach attempts fail.

The packaging report records the layout settings, background and `.DS_Store` digests, drawing/layout script and vendored tool-tree digests, full image payload digest, and separate writable-layout/final-integrity results, including the decoded background alias target. `commands.jsonl` retains the background/metadata generation, conversion and verification commands. `DMG-PAYLOAD-MANIFEST.tsv` includes every retained background, layout and attachment byte. Known filesystem housekeeping directories created only on the writable image are explicitly removed and recorded; other unexpected members fail verification. These are metadata/integrity checks: `visualInspection` remains `not-run` until a person or UI check opens the final image and records its actual appearance. Finder metadata can vary across machines, so this stage does not claim byte-reproducible DMGs.

## Local verification

```sh
python3 -B -m unittest discover -s scripts/release -p 'test_package_preview.py'
python3 -B -m unittest discover -s scripts/release -p 'test_assemble_release.py'
```

The DMG path also requires an actual macOS `hdiutil` create/mount/copy/unmount run and strict signature checks on the copied App. These checks validate distribution integrity on the build Mac; they do not substitute for another Mac, minimum-OS, Gatekeeper, cloud service or full workflow testing.
