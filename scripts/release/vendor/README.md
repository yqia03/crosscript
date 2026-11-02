# DMG layout build tools

Pinned, unmodified Python sources from `ds_store` 1.3.3 and `mac_alias` 2.2.3, distributed by the dmgbuild maintainers. Both use the MIT license; the original full license texts are retained beside the packages. `provenance.json` records upstream repositories, exact wheel names and hashes, and a SHA-256 for every retained source/license file. These packages are build tools and are not copied into the App or installation image. They need only the Python standard library on macOS. Do not install them globally.

The layout script generates metadata directly, following the upstream dmgbuild approach: create the background alias from the actual mounted image, then write the Finder settings and icon positions through `DSStore`. No Finder, user Finder preferences, AppleScript, accessibility or Automation access is used.

Primary references: [dmgbuild documentation](https://dmgbuild.readthedocs.io/en/latest/), [official implementation](https://github.com/dmgbuild/dmgbuild/blob/main/src/dmgbuild/core.py), [ds_store](https://github.com/dmgbuild/ds_store), [mac_alias](https://github.com/dmgbuild/mac_alias).
