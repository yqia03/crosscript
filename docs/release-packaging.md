# Build the three release downloads

New releases provide **DMG**, **App ZIP**, and **complete materials**. The DMG is the recommended installation choice: open it in Finder, drag `TranslationWorkbench.app` to `Applications`, eject the image, then open the installed app. The ZIP contains the same App and is an alternative, not an additional required download. Both use the current ad-hoc signature; neither is notarized.

中文：普通用户下载 DMG 或 App ZIP 其中之一即可。DMG 打开后将 `TranslationWorkbench.app` 拖入 `Applications`，推出磁盘映像，再从应用程序目录打开。完整材料包供需要源码、第三方材料或验证记录的用户下载，不是运行 App 的必需步骤。

The existing [build 5 release](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5), its tag and all its assets are preserved. The policy applies from build 6. GitHub's two automatic source links are outside the uploaded-asset count.

## Prepare a fresh candidate

1. Commit the final source, version/build, matching license-window release tag and bundled legal/source instructions. Do not modify an App after signing.
2. Run `python3 -B scripts/release/build-bound-candidate.py --source "$PWD" --output /path/to/new-candidate` from a clean checkout. Its exact source archive and build metadata must match the signed App.
3. Package the same App twice using `scripts/release/package-preview.py`, once with `package` and once with `package-dmg`. Each stage needs a separate new output directory; pass `--app`, `--source`, `--source-root`, `--notice-root`, `--version`, `--build` and `--output`. The source SHA is the candidate's build-input commit, not a later documentation commit.
4. Verify the App's selected runtime against the third-party companion. When the runtime is unchanged, the existing exact companion archive can be included without renaming its internal records or claiming new component tests. Record which build supplied it and why it applies.
5. Collect build binding, source manifest, ZIP/DMG packaging reports, focused test results and actual installation results in a new evidence directory. Preserve historical records as historical; do not convert `not-run` into passing results.

## Assemble only the public downloads

```sh
python3 -B scripts/release/assemble-release.py \
  --dmg /path/to/dmg/Crosscript-preview-0.1.0-6.dmg \
  --zip /path/to/zip/Crosscript-preview-0.1.0-6.zip \
  --source-archive /path/to/candidate/Crosscript-source-0.1.0-6.tar.gz \
  --third-party-archive /path/to/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz \
  --evidence-dir /path/to/evidence \
  --source-commit FULL_BUILD_INPUT_SHA \
  --version 0.1.0 --build 6 \
  --output /path/to/new-release
```

Only the three files in the generated `assets/` directory are uploaded. `RELEASE.md`, `release-manifest.json` and the outer checksum file remain local; the Release body displays checksums and links to complete materials. The materials archive preserves the exact source under `source/`, the third-party archive under `third-party/`, and records under `evidence/`, with an internal manifest and checksums. Each uploaded file must be smaller than GitHub's 2 GiB asset limit; exceeding it fails assembly rather than silently adding another asset.

Upload to a **new** version/tag; never use an overwrite flag or modify build 5. Verify the remote release has exactly the three expected uploaded names, sizes and digests, plus working download links. The generated source links are not an installation option. A release publication does not change recorded test outcomes.

## Local verification

```sh
python3 -B -m unittest discover -s scripts/release -p 'test_package_preview.py'
python3 -B -m unittest discover -s scripts/release -p 'test_assemble_release.py'
```

The DMG path also requires an actual macOS `hdiutil` create/mount/copy/unmount run and strict signature checks on the copied App. These checks validate distribution integrity on the build Mac; they do not substitute for another Mac, minimum-OS, Gatekeeper, cloud service or full workflow testing.
