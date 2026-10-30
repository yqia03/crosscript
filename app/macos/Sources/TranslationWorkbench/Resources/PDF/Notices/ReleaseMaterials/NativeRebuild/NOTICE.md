# 原生依赖受控重建说明

本说明保留 build 4 中 2026-10-27 的 GMP／ZeroMQ 重建记录；build 5 的 `babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3` 继续使用这两库的相同字节。以下“其他载荷未改”限定于当时的 GMP／ZeroMQ 构建阶段；build 5 另行重建两份 OpenSSL 库，见 [OpenSSL 修改通知](../OpenSSLRebuild/NOTICE.md)。2026-10-27 受控重建并替换 OpenCV wheel 内的 GMP 6.3.0 与 ZeroMQ 4.3.5，保留 libsodium、soxr 和其他上游载荷字节。旧工作区、旧 runtime 与 build 3 不变。本轮只完成本地原生库的聚焦验证，不能据此宣称整个预览版已可公开发布，也不宣称 OpenCV 全部 86 项嵌套库的原始构建关联已经完成。

## 许可证与完整源码

`notices/` 原样保存 12 个上游许可证、作者和相关说明文件。GMP 的原 README 保留 LGPL-3.0-or-later 与 GPL-2.0-or-later 等原许可选择及适用说明；ZeroMQ 保留 MPL-2.0 和附带 Unity/wepoll 通知；libsodium 保留 ISC 许可证和作者名单。本摘要不重新许可这些组件，也不改变 Crosscript 自有代码 AGPL-3.0-only 的选择。

同版完整材料应以 `Crosscript-third-party-0.1.0-5-materials-v4.tar.gz` 一并交付。展开后的入口是 `Crosscript-third-party-materials-v4/CURRENT-INDEX.json`、`current/native-index.json` 与 `current/native/`。后者包含三个精确源码包、构建/重打包/隔离安装脚本、配置和检查记录；各官方来源、压缩包 SHA-256、逐通知文件 hash 见本目录 `compact-index.json`。本应用内摘要不重复携带大型源码或二进制。

## 精确替换与构建配置

- 最终 wheel：`opencv_python_headless-5.0.0.93-2crosscriptnative-cp37-abi3-macosx_14_0_arm64.whl`，48,349,664 字节，SHA-256 `bfd3c1684a0eb4ef7d6763d7adbcddbd23e7d55ebc931e0ccaf68374ea0ee5a6`。
- `libgmp.10.dylib`：484,688 字节，SHA-256 `ade1a64325a2418f4ea6143ab0914ba1eaf62496b307fd8e05b1a02cd460498c`。
- `libzmq.5.dylib`：688,112 字节，SHA-256 `3ec540381c648b832af9089faa54dfb292012bc6261ea82dcf7619236b629d35`。

GMP 与 ZeroMQ 的上游实现源码没有补丁。构建使用 Apple clang 21.0.0、macOS SDK 27.0，目标 arm64/macOS 14.0；App 最低 macOS 14.2 不变。GMP 开启 shared/C++、关闭 static；ZeroMQ 使用 kqueue，开启 CURVE/libsodium 和 WS，关闭 draft/PGM/NORM/GSSAPI。完整参数见材料中的 `current/native/provenance.json`。

额外固定 `libzmq_cv_so_bindtodevice=no`，避免新 SDK 自动启用旧库没有的 SO_BINDTODEVICE 行为，并维持旧库的 ENOTSUP 结果。libsodium 二进制不变，使用 1.0.20 源码头文件并从源码常量生成 `version.h`；其 Mach-O current version 29.0.0 是 ABI 版本。原 libsodium 与官方 bottle 的 UUID/代码段对应证据随材料保留。

处理顺序为编译、install name/相对依赖、strip、ad-hoc 签名、strict 验签、RECORD 和最终 wheel hash。原包元数据/许可证继续保留；独立重新打包得到相同 wheel 字节。不同工具链构建不保证 dylib 字节完全相同。

## 已验证与尚待验收

GMP 上游检查为 199 PASS、1 条条件性 SKIP、0 FAIL；公开符号集合保持 GMP 610、ZeroMQ 74。隔离 runtime 安装后完成 RECORD/严格签名/实际加载库检查、cv2 合成图像缩放及 GMP/ZeroMQ 聚焦离线 API 检查。仅在本机进程内运行 ZeroMQ 通信与本机 CURVE 一致性检查；没有模型、远程、付费服务或 Issue #33 探测。

本 runtime 有 84 个 wheel，其中两个本地修改包分别是本 OpenCV 包与另行说明的 BabelDOC 字体集成包；合计 22 个随应用交付载荷和 245 个 HTTPS 载荷。这个数量划分不代表安装验收完成。四个现有工作流保留，其完整回归、最终候选源码/材料/包绑定和签名、普通第二台 Apple Silicon Mac 实装、人工公开审阅与发布授权仍是独立门槛。应通过独立源码副本更新 wheel、manifest、runtime ID 与 inventory 后重建，不能只覆写正在使用的 dylib。
