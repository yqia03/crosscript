# Build 5 native distribution and recipient materials

Evidence review for [#4](https://github.com/yqia03/crosscript/issues/4), checked 2026-11-01 against the [build 5 baseline](baseline.md). The selected native bytes and their delivered source/notice/build records can be joined without changing the release. This review establishes distribution membership and the stated evidence strengths; it does not certify every original producer build, every static dependency or every replacement operation.

Use the published [materials archive](https://github.com/yqia03/crosscript/releases/download/v0.1.0-preview.5/Crosscript-third-party-0.1.0-5-materials-v4.tar.gz), SHA-256 `25049788ea1f9b1c638164e2743d0089b71d828ce0729c28d02238bfd375cf89`. Paths below are relative to its `Crosscript-third-party-materials-v4/` root. Start at `CURRENT-INDEX.json`, then `current/native-index.json` (SHA-256 `7ddc87660bda36fc8cf80c14c29e5ae5641d37dcf66689b7810b3d06d4e1d3de`). Historical files under `origin-materials/2026-10-26/` supply retained evidence, not current selection authority.

## Exhaustive membership and structural closure

[native-verification.json](native-verification.json) records a fresh read-only scan of every regular file in the preserved build 5 freshly installed runtime using Mach-O/fat binary magic, followed by SHA-256 and size comparisons. All **451** objects matched #2's assigned identities and the current native index, with **zero missing or extra regular Mach-O files**. Internal symlink aliases are not counted twice. This is an installed-runtime observation, not a claim the whole runtime is bundled inside the preview ZIP. [#3](https://github.com/yqia03/crosscript/issues/3) covers the selected Python/wheel input and installer boundary.

The preview ZIP independently contains **one** native regular file: `TranslationWorkbench.app/Contents/MacOS/TranslationWorkbench`, 13,492,896 bytes, SHA-256 `da0e75ea0c65631cdf43d64e90b3f6a82f97d3482d4a8521ed14437f9f8ff41d`. It is own App code, covered by the source/build binding in #3/#8, rather than an unassigned third-party runtime row. Packaged wheel containers can contain copies of the same native members; they are not additional logical runtime components.

All **100** native members of selected `current/openssl/artifacts/opencv_python_headless-5.0.0.93-3crosscriptopenssl-cp37-abi3-macosx_14_0_arm64.whl` were independently enumerated and matched their member-index and installed-file hashes and sizes. Wheel SHA-256 is `4f8048e641ec2a06c70e1e092cd4271ebd5cf94d9311b3125992dcc5efa8638d`. The inventory includes FFmpeg and nested codec, crypto, font and other libraries regardless of whether an application workflow calls them. There was no invocation-based exclusion.

The indexed load commands yield **1,156 dependency entries**: **332** resolve to distributed native targets and **824** are Apple `/System/Library/` or `/usr/lib/` references. Relative paths, rpaths and internal aliases were resolved against the preserved runtime; no indexed non-system edge remained unresolved. `distributedLoadTargetRows` in the machine record identifies nested targets for each object through zero-based row references. This structural check reused byte-bound current load metadata; it did not rerun dyld or prove that every optional feature works. System references are distinguished from distributed payloads. Static linkage and future `dlopen` choices cannot be inferred completely from these edges.

The current index's architecture fields remain authoritative: the freetype-py library is universal `x86_64` + `arm64`; the distribution is not 451 arm64-only objects. Library ABI filenames/current versions are not substituted for source versions.

## Source, configuration and notice joins

For every native object, the machine record supplies the #2/current-index pointer, independent byte-match result and the exact per-file historical source/notice/build record. The current-index pointer supplies its exact path, version, digest, size and material status; `indexAliases` expands the short record prefixes. `componentRecords` supplies component-level pointers. A null `selectedBuildProvenance` means there is no separate current controlled-replacement record for that object; it does not mean source is absent or the original build is reproduced.

Seven source indexes cover the retained material families:

| Index path | How to use it |
| --- | --- |
| `origin-materials/2026-10-26/gap-closure-v2/native/opencv-86-original-inputs.reconciled.json` | 69 component records for the original 86 nested OpenCV objects; exact source archives/hashes, actual formulas, patches, full source notices, supplemental/bottle notices and comparison evidence. Current replacements override four old objects. |
| `origin-materials/2026-10-26/gap-closure-v2/native/other-native-index.json` | 346 files / 35 owner components: 322 package-notice cases, 11 standalone Python/Tcl cases, five exact copyleft-source cases, three Eigen/MPL cases, five supplemented nested-notice cases. |
| `origin-materials/2026-10-26/gap-closure-v2/native/gcc/index.json` | Three SciPy runtime libraries, exact GCC source, actual formula, Darwin patch, full notices and code/UUID association. |
| `current/native/source-index.json` | Controlled GMP/ZeroMQ source archives and complete original license/author material; exact libsodium headers and unchanged-library relationship. |
| `current/rav1e/index.json` | rav1e 0.8.0 locked-source/notice material; 273 packages (271 registry + two local), explicitly a build/development/platform superset. |
| `current/openssl/source-index.json` | Unmodified OpenSSL 3.6.0 source, full Apache notice, exact external official-wheel input and controlled sibling-library references. |
| `current/native-selected-inputs.json` | Retained signed GMP/ZeroMQ output identities and exclusion of the superseded `2crosscriptnative` wheel. |

This review freshly rehashed **2,518 unique delivered files** referenced by the scoped native/source/provenance indexes, checking **4,211 indexed SHA-256 comparisons** with zero mismatches; 2,275 files have indexed digests, while 243 have presence/observed hashes without an expected digest in those references. Resolution used the explicit `verification/origin-reference-map.json`, whose digest and result-ledger digest are recorded in the machine report. In particular, historical `third-party/` and `gap-closure-v2/` paths are not blindly resolved relative to the containing JSON. This check verifies the referenced material bytes and presence, not that every upstream build used every retained optional input. Entry-point hashes are recorded separately. The outer materials/archive and checksum verification is independent of this scoped join.

The original 16 already assessed objects additionally join `origin-materials/2026-10-26/third-party/native/native-component-index.json`: eight FFmpeg libraries, Rubber Band, vid.stab, x264, x265, soxr, freetype-py's FreeType/HarfBuzz, and two libspatialindex libraries. The evidence strengths below preserve the difference between retained source and reproduced/associated builds.

| Family | Exact retained materials and evidence | Remaining boundary |
| --- | --- | --- |
| FFmpeg 7.1.1 / Homebrew 7.1.1_3, eight dylibs | Official n7.1.1 commit `db69d06eeeab4f46da15030a80d539efb4503ca8` source; actual matching bottle formula; SVT-AV1 and Chromium patches; full original notices. All eight original UUID/code-segment hashes match the official bottle. Embedded configuration includes `--enable-gpl --enable-version3`. | Strong producer correspondence; not whole-file reproduction or complete codec/runtime functional acceptance. Retained package/source notices apply to actual nested libraries separately. |
| Original 86 OpenCV nested objects | 82 originally matched official-bottle UUID + `__TEXT,__text` hashes. Exact source/formula/patch and notice references are per component. | Four old exceptions were GMP, ZeroMQ and the two OpenSSL files; current controlled records below replace their old associations. The old 82/86 count is not a fresh build 5 test count. |
| Rubber Band 4.0.0; vid.stab 1.1.1 | Exact source/full terms and matching bottle's actual formula; UUID + code correspondence. | Their dependencies are separate rows, not implicitly cleared by their association. |
| x264 r3108 / `31e19f92f00c7003fa115047ce50978bc98c3a0d`; x265 `4.1+1-1d117be` | Exact commit/archive and version evidence, complete original COPYING/headers, fixed formulas; two x265 CMake patches. Preserve upstream “or later” terms where present. | Exact original bottle/build/packaging association is not proved; which x265 patch/configuration the old producer used remains unknown. |
| soxr 0.1.3 | Source `b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889`, ARM64 patch `9df5737a21b9ce70cc136c302e195fad9f9f6c14418566ad021f14bb34bb022c`, full LGPL/author material and historical formula. | Version correspondence, not proof of the selected original producer recipe. The recipient replacement experiment below uses different bytes. |
| SciPy GCC runtime 13.4.0 | `gcc/index.json` + `gcc/gcc-bottle-association.json`; complete source `9c4ce6dbb040568fdc545588ac03c5cbc95a8dbf0c7aa490170843afb59ca8f5`, actual bottle formula, Darwin patch and per-library notices. Three UUID/code associations match. | Old truncated-download failure was resolved in the later GCC index. `libgcc_s` / `libgfortran` retain GPL + GCC exception; `libquadmath` has its separate LGPL terms. No GCC rebuild/replacement operation was run here. |
| freetype-py 2.5.1: FreeType 2.13.2 + HarfBuzz 8.3.0 | Exact archives and upstream hash-pinned `setup-build-freetype.py`, setup/CI scripts; static version evidence; full FreeType FTL/GPL texts plus HarfBuzz copyrights/authors. | Strong version correspondence; complete original build/static membership is not proved. Preserve the applicable FreeType license choice/attribution, rather than relabeling everything AGPL. This is distinct from OpenCV's FreeType 2.13.3 and HarfBuzz 11.2.1. |
| rtree 1.4.1: libspatialindex 2.1.0, two dylibs | Exact official 2.1.0 source, source CMake/version files and full MIT/author notices; wrapper build material retained in the package source. | Version correspondence; the extra Homebrew formula is a reference, not established rtree-wheel production configuration. |
| CPython 3.12.15 standalone | Fixed standalone revision `9e40cba825ca0997a01cab9f60a0b15ffb976af2`, exact CPython and standalone input archives; native owner record includes full Python and 105,875-byte standalone license collection. Tcl 9.0.4 source actually includes itcl 4.3.8 and thread 3.0.6. | Input/build definitions are retained; do not assert all optional definitions were linked. Bootstrap/input selection is #3. This review does not reproduce the standalone producer build. |
| Levenshtein 0.27.5; PyMuPDF 1.28.2 | Five native objects: exact official sources, source build entry points, full original terms in primary companion. | Source presence is established; exact native rebuild and per-library replacement execution were not performed. See #3 for Python/wheel integration. |
| ml-dtypes 0.6.0; ONNX Runtime 1.31.0 | Three objects join fixed package sources plus included/pinned Eigen/MPL materials and notices. | No unsupported closed-source exception or claim all optional static components were linked. Exact producer configuration/static membership remains qualified by component records. |
| Pillow 12.3.0; lxml 6.1.3; scikit-learn 1.9.1 | Pillow's 70,282-byte consolidated license retains nested imaging/font terms; lxml LICENSES covers zlib/iconv/libxml2/libxslt/libexslt/PSF; sklearn COPYING names bundled libomp and preserves Apache + LLVM exception/legacy LLVM texts. | These are actual retained package/nested notices; package-notice classification does not establish exhaustive static linkage or universal source obligations. |
| backports-zstd 1.8.0; hyperscan 0.9.1; uharfbuzz 0.56.3 | Exact sources/notices retain Zstandard 1.5.7; VectorScan 5.4.12 / PCRE 8.45 / Boost 1.87.0; HarfBuzz 14.6.0 respectively. Wrapper/build references and embedded versions are recorded. | Build-only Ragel is not asserted shipped; optional/source supersets remain distinct from compiled membership. |
| cryptography 50.0.2 | Embedded OpenSSL 4.0.3 has distinct retained official notices. Exact cryptography source/Cargo.lock, 32 locked registry source crates and 62 full notices are retained. | The crate list includes optional/build/platform dependencies. This copy is distinct from standalone Python's OpenSSL 3.5.9 and controlled OpenCV OpenSSL 3.6.0. |

## Controlled selected builds: three separate chains

The four signed-library output hashes below were freshly compared across selected artifact files, installed files and provenance/build results. They are in the selected final wheel. GMP's build-1 bytes were explicitly reused in build-2; build-1's earlier ZeroMQ bytes are intermediate history. Both controlled source indexes record no implementation source patches.

| Selected output | SHA-256 | Build/configuration and historical operation evidence |
| --- | --- | --- |
| GMP 6.3.0 `libgmp.10.dylib`, 484,688 bytes | `ade1a64325a2418f4ea6143ab0914ba1eaf62496b307fd8e05b1a02cd460498c` | `current/native/provenance.json`, `records/build-1/result.json`: source `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898`; shared/C++, no static, arm64/macOS 14.0. Recorded upstream result 199 PASS / one conditional arm64 SKIP / zero FAIL; 610 exports match. |
| ZeroMQ 4.3.5 `libzmq.5.dylib`, 688,112 bytes | `3ec540381c648b832af9089faa54dfb292012bc6261ea82dcf7619236b629d35` | Same provenance + `records/build-2/result.json`, static review and bind-to-device record: kqueue/CURVE/libsodium/WS, drafts/PGM/NORM/GSSAPI disabled; `libzmq_cv_so_bindtodevice=no` preserves original ENOTSUP behavior. Recorded 74-export match and offline PAIR/poll/multipart/REQ-REP/Z85/CURVE checks. Unchanged libsodium 1.0.20 retains exact source headers/version generation and original bottle association. Full network/IPC upstream suite was not run. |
| OpenSSL 3.6.0 `libcrypto.3.dylib`, 5,278,192 bytes | `13aa519f1e6d13d3eb3968448e1166e5de03b70fa7b4ec5282e5c21318ab855e` | `current/openssl/{source-index,provenance,result,verification}.json`, `records/build-commands.json`, generated config and ABI records: source `b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9`; Apple Clang 21 / SDK 27, arm64/deployment 13.0. |
| OpenSSL 3.6.0 `libssl.3.dylib`, 996,160 bytes | `a2bdd0fd427991bdf846b87f1af9f697c6fae9f208accdb9dfad142b958b319d` | Same chain: `darwin64-arm64-cc enable-ec_nistp_64_gcc_128 no-ssl3 no-ssl3-method no-zlib`. Recorded 12 upstream recipes / 500 harness checks, exact export sets (8,996 crypto / 2,005 ssl), 641 consumer imports, memory TLS 1.2/1.3 and crypto probes. No real network TLS/SFTP/SRT or paid services. |

`current/openssl/result.json` retains its build-phase “awaiting compatibility” marker; subsequent `verification.json` and provenance describe the later completed focused checks. Default OpenSSL config/module paths are retained for compatibility; no global Homebrew installation is required or performed. Generated config snapshots are sanitized reference records, not directly reusable Makefiles. `SOURCE_DATE_EPOCH` is not actual build-time evidence.

These are source/configuration/output chains for the **selected local builds**. The original producers' replaced GMP/ZeroMQ/OpenSSL recipes remain historically unproved. That fact neither disproves the new controlled chains nor proves the old builds. Historical operation results were read here, not rerun. Only the OpenSSL pair changed in the final overlay; the other 98 native wheel members, including retained GMP/ZeroMQ, stayed byte-identical to its precursor.

## Rebuild, replacement and installation instructions

The archive delivers complete upstream source/notices plus scripts under their original licenses. Own scripts remain AGPL-3.0-only; that does not relicense upstream libraries. Recipient instructions are per family and do not promise arbitrary-toolchain bit-identical recompilation.

| Route | Delivered entry points | Usable scope and limits |
| --- | --- | --- |
| Rebuild controlled GMP/ZeroMQ | `current/native/README.zh-CN.md`, `prepare_inputs.py`, `build_native.py`, `repack_wheel.py`, `source-index.json`, exact executed helpers/config/commands in `records/build-*` | Apple Silicon + existing CLT/Python; new output directories; exact official wheel input; child-process deny-network policy; no global install. Build, edit install names/relative dependencies, strip, ad-hoc sign/strict verify, regenerate RECORD and wheel hash in that order. The retained README names the historical precursor wheel; current selection is `current/native-selected-inputs.json` + OpenSSL overlay. |
| Rebuild OpenSSL / replay final wheel | `current/openssl/README.zh-CN.md`, `build_openssl.py`, `repack_from_official.py`, `repack_wheel.py`, source/config/command/ABI records | Exact wheel replay uses the retained signed libraries plus official original wheel SHA-256 `030ca5e0837a2963ab36ef896baa9767eb8d2b83353fb28af5a521e40dd8756f`. `records/portable-replay.json` records exact final-wheel reproduction. Its predecessor wheel is scratch only and intentionally not redistributed. User-recompiled bytes take the documented derivative-wheel route with their own version, hashes and manifest. Future upstream online availability is not a permanent-archive guarantee. |
| Other shared native components | Per-object source/patch/formula/build files in the historical native indexes; original upstream build entry points; recipient soxr helper below | Sources and applicable full notices are retained. Library-specific build/configuration evidence has the strength in the table above. The soxr example demonstrates one route; it is not an executed libquadmath, all-LGPL, full-FFmpeg or universal relink result. Unexecuted per-component replacement remains an evidence limit. |
| Official cache versus self-built runtime | `origin-materials/2026-10-26/gap-closure-v2/rebuild/delivery/README.md` + `rebuild_soxr.py`; controlled overlay READMEs | A recipient can use their own normal installed runtime/official cached wheel, or a separately identified self-built derivative. No publisher-private runtime/cache is a required input. Retain complete source/patches/notices and local provenance; changes must satisfy the installer/health/inventory boundaries. |

Representative operation evidence is `origin-materials/2026-10-26/gap-closure-v2/rebuild/delivery/result.sanitized.json`. It records building a **different** compatible soxr 0.1.3 dylib (`cd7aa14ad91041f98c7e816f41ee7e252d242f12246e03bb92126243b46bd290`) from delivered source + ARM64 patch using direct Clang, explicit upstream source list and generated configuration. It retains the install ID, has no missing public `soxr_*` exports, passes strict signature and 145 RECORD entries, installs into an isolated wheel/runtime, and confirms dyld actually loads the changed library. The original installer returned `reused=true`; no download phase occurred. Synthetic 512-sample resampling matched identity exactly and downsampling within the recorded `1e-4` tolerance.

That is a **historical recipient-style example with an earlier source/runtime/wheel**, not the selected build 5 output, fresh App/UI acceptance, whole-runtime source build or replacement evidence for every LGPL library. It proves the bounded library-replacement route described by that record. Build 5 reuse/installation scope is independently documented; old runtime IDs and `readyForPublication=false` markers must not be edited into new results.

For one's own derivative, work in a stopped, isolated runtime/data directory. Regenerate wheel RECORD, selected wheel/hash/manifest and runtime inventory; preserve the derivative identity. If the App's bundled inputs or source selection changes, create its own runtime ID and complete App signing/package verification. A compatible locally inventoried runtime can follow the documented installer reuse route without falsely claiming it has official bytes. Never copy one dylib over a running managed runtime or bypass its integrity checks. `WORKBENCH_PDF_RUNTIME` alone changes Python selection, not installer/model/assets selection. Preserve a complete original directory/inventory for rollback. No system security exception or quarantine removal is needed by these instructions.

## Exact remaining evidence limits and follow-through

| Unproved or unexecuted item | Current evidence / next boundary |
| --- | --- |
| Original replaced GMP/ZeroMQ/OpenSSL producer recipes | Historical gap retained; selected current controlled builds have their own chain. No byte change follows solely from that historical gap. |
| Exact old x264, x265, soxr and rtree/libspatialindex production configuration; complete freetype-py production/static membership | Versions, sources, patches/reference recipes and original notices retained at the explicitly limited strength above. Obtain producer/build association if stronger provenance is required; do not turn source availability into a reproduction claim. |
| All optional/static dependencies of CPython, permissive wheels, Eigen users, cryptography and rav1e | Actual owner/nested notice records plus source/lock supersets retained. Compiled membership is not completely established by source/lock presence or load commands. |
| Recipient rebuild/replacement for every covered native library | Detailed original build/source material exists and selected controlled/soxr examples are bounded evidence. All other component replacements/relinks, including libquadmath, were not executed here. Their outcome remains unknown. |
| Every possible license branch/condition or downstream distribution arrangement | Full original texts/author records remain the authority. This inventory is technical evidence and does not issue blanket legal clearance, infer a universal source obligation for permissive libraries, or demand replacement/purchase solely because a component is GPL. |
| Build 5 second Mac and macOS 14.2 physical/whole-workflow acceptance | Second-Mac B01–B06 were not run and waived on 2026-10-30; minimum-system hardware and full functional gaps remain as published. Build 4 results do not transfer. |

No new missing current native object, non-system load target or selected/reference hash mismatch was found. This does not erase the qualified provenance/static-membership/replacement gaps above. No frozen byte was changed, no library was rebuilt, and no App, provider, paid request or stopped PDF batch was run. If a later remedy changes selected bytes, return to [#2](https://github.com/yqia03/crosscript/issues/2) for new identities and repeat affected #3/#4/#7–#10 source, manifest, signing, load, installation and package checks.

## Every current component/version group

This table is derived from all 451 current rows, including unused distributed objects. Each group retains its per-file exact evidence pointer in [native-verification.json](native-verification.json); it is not a count of independently rebuilt components. Codes: **B** = source/notices + original bottle code/UUID correspondence; **C** = selected controlled build; **S** = strong historical correspondence; **V** = version correspondence; **P** = package/notices with no exhaustive static-build assertion; **N** = specific nested notice/source supplement; **E** = Eigen/MPL material; **Y** = standalone input/build material; **F** = exact copyleft source/full terms. The preceding tables define the limits and applicable recipient routes.

| Component / native version | Objects | Evidence |
| --- | ---: | --- |
| GCC runtime / 13.4.0 | 3 | B |
| aom / 3.12.1 | 1 | B |
| aribb24 / 1.0.4 | 1 | B |
| backports-zstd / 1.8.0 | 1 | N |
| bitarray / 3.12.2 | 2 | P |
| brotli / 1.1.0 | 3 | B |
| cffi / 2.1.1 | 1 | P |
| chardet / 7.6.0 | 15 | P |
| charset-normalizer / 3.5.2 | 2 | P |
| cjson / 1.7.18 | 1 | B |
| cpython-standalone-or-unassigned / 3.12.15 | 11 | Y |
| cryptography / 50.0.2 | 1 | N |
| dav1d / 1.5.1 | 1 | B |
| fontconfig / 2.16.0 | 1 | B |
| freetype / 2.13.3 | 1 | B |
| freetype-py / FreeType 2.13.2 with HarfBuzz 8.3.0 | 1 | S |
| fribidi / 1.0.16 | 1 | B |
| gettext / 0.25 | 1 | B |
| giflib / 5.2.2 | 1 | B |
| glib / 2.84.3 | 1 | B |
| gmp / 6.3.0 | 1 | C |
| gnutls / 3.8.9 | 1 | B |
| graphite2 / 1.3.14 | 1 | B |
| harfbuzz / 11.2.1 | 1 | B |
| hf-xet / 1.7.0 | 1 | P |
| highway / 1.2.0 | 1 | B |
| hyperscan / 0.9.1 | 1 | N |
| imath / 3.1.12 | 1 | B |
| jiter / 0.17.0 | 1 | P |
| jpeg-turbo / 3.1.1 | 1 | B |
| jpeg-xl / 0.11.1_1 | 3 | B |
| lame / 3.100 | 1 | B |
| leptonica / 1.85.0 | 1 | B |
| levenshtein / 0.27.5 | 1 | F |
| libarchive / 3.8.1 | 1 | B |
| libass / 0.17.4 | 1 | B |
| libavif / 1.3.0 | 1 | B |
| libb2 / 0.98.1 | 1 | B |
| libbluray / 1.3.4 | 1 | B |
| libdeflate / 1.24 | 1 | B |
| libidn2 / 2.3.8 | 1 | B |
| libogg / 1.3.5 | 1 | B |
| libpng / 1.6.49 | 1 | B |
| librist / 0.2.11 | 1 | B |
| libsamplerate / 0.2.2 | 1 | B |
| libsodium / 1.0.20 | 1 | B |
| libssh / 0.11.1 | 1 | B |
| libtasn1 / 4.20.0 | 1 | B |
| libtiff / 4.7.0 | 1 | B |
| libunibreak / 6.1 | 1 | B |
| libunistring / 1.3 | 1 | B |
| libvmaf / 3.0.0 | 1 | B |
| libvorbis / 1.3.7 | 2 | B |
| libvpx / 1.15.2 | 1 | B |
| libx11 / 1.8.12 | 1 | B |
| libxau / 1.0.12 | 1 | B |
| libxcb / 1.17.0 | 4 | B |
| libxdmcp / 1.1.5 | 1 | B |
| little-cms2 / 2.17 | 1 | B |
| lxml / 6.1.3 | 7 | P |
| lz4 / 1.10.0 | 1 | B |
| markupsafe / 3.0.4 | 1 | P |
| mbedtls / 3.6.3.1 | 1 | B |
| ml-dtypes / 0.6.0 | 1 | E |
| msgpack / 1.2.3 | 1 | P |
| nettle / 3.10.1 | 2 | B |
| numpy / 2.5.4 | 19 | P |
| onnx / 1.23.2 | 1 | P |
| onnxruntime / 1.31.0 | 2 | E |
| opencore-amr / 0.1.6 | 2 | B |
| soxr (OpenCV) / 0.1.3 | 1 | V |
| vid.stab (OpenCV) / 1.1.1 | 1 | S |
| Rubber Band (OpenCV) / 4.0.0 | 1 | S |
| x265 (OpenCV) / 4.1+1-1d117be | 1 | V |
| opencv-python-headless / 5.0.0.93 | 1 | P |
| FFmpeg (OpenCV) / 7.1.1 / Homebrew 7.1.1_3 | 8 | S |
| x264 (OpenCV) / r3108 / 31e19f92f00c7003fa115047ce50978bc98c3a0d | 1 | V |
| openexr / 3.3.4 | 4 | B |
| openjpeg / 2.5.3 | 1 | B |
| openssl@3 / 3.6.0 | 2 | C |
| opus / 1.5.2 | 1 | B |
| orjson / 3.11.3 | 1 | P |
| p11-kit / 0.25.5 | 1 | B |
| pcre2 / 10.45 | 1 | B |
| pillow / 12.3.0 | 26 | P |
| protobuf / 7.36.2 | 1 | P |
| psutil / 7.2.2 | 1 | P |
| pydantic-core / 2.50.1 | 1 | P |
| pymupdf / 1.28.2 | 4 | F |
| pyyaml / 6.0.3 | 1 | P |
| rapidfuzz / 3.14.6 | 5 | P |
| rav1e / 0.8.0 | 1 | B |
| regex / 2026.9.29 | 1 | P |
| rtree / 2.1.0 | 2 | V |
| ruff / 0.17.0 | 1 | P |
| scikit-image / 0.26.0 | 54 | P |
| scikit-learn / 1.9.1 | 70 | P |
| scipy / 1.18.1 | 106 | P |
| sdl2 / 2.32.8 | 1 | B |
| snappy / 1.2.2 | 1 | B |
| speex / 1.2.1 | 1 | B |
| srt / 1.5.4 | 1 | B |
| svt-av1 / 3.0.2 | 1 | B |
| tesseract / 5.5.1 | 1 | B |
| theora / 1.1.1 | 2 | B |
| tibs / 2.0.2 | 1 | P |
| tiktoken / 0.14.0 | 1 | P |
| uharfbuzz / 0.56.3 | 2 | N |
| webp / 1.5.0 | 3 | B |
| xz / 5.8.1 | 1 | B |
| zeromq / 4.3.5 | 1 | C |
| zimg / 3.0.5 | 1 | B |
| zstd / 1.5.7 | 1 | B |
