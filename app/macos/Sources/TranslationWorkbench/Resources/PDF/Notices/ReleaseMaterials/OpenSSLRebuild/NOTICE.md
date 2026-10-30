# OpenSSL 3.6.0 — controlled Crosscript rebuild

The selected OpenCV wheel uses locally rebuilt OpenSSL 3.6.0 `libcrypto.3.dylib` and `libssl.3.dylib`. OpenSSL remains under Apache-2.0; the full unmodified license is in `LICENSE.txt`. Copyright and applicable original notices are retained in the complete official source archive.

Crosscript rebuilt the exact official source without source patches, kept the library ABI/install names and original default configuration/module lookup paths, adjusted the SSL-to-crypto load path, stripped debug symbols, and applied ad-hoc integrity signatures. This is a Crosscript derivative build, not an official OpenSSL or Homebrew binary. Other OpenCV payloads, including the previously controlled GMP/ZeroMQ libraries, retain their selected bytes.

Matching source, configuration, build/repack/install instructions, exact inputs, outputs and focused offline verification are in **Crosscript-third-party-0.1.0-5-materials-v4.tar.gz**, under `Crosscript-third-party-materials-v4/current/openssl/`. Start at `provenance.json`, `source-index.json` and `README.zh-CN.md`. `compact-index.json` binds the exact source, two libraries and modified wheel. The companion's current indexes identify this candidate; historical records do not override them.

The old original-producer build association was not proven. The selected replacements instead have a recorded controlled build; this does not retroactively prove that old build. Exported symbols, default algorithms, in-memory TLS/crypto and scoped upstream tests were checked, not all possible environments or network services. A separate Mac must validate the new candidate; prior build 4 acceptance is not automatically inherited.

中文：两份 OpenSSL 库使用固定官方 3.6.0 源码受控重建，源码无补丁，原许可证及通知保留；保留既有 ABI 和配置路径，仅对部署载入路径、调试信息及完整性签名作明确处理。完整来源和复现材料见上述 materials-v4，公开地址由应用的源码与材料入口提供；正式发布前这些地址仍可能不可访问。
