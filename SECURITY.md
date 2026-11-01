# Security policy / 安全政策

## Report privately / 私密报告

Use [GitHub private vulnerability reporting for yqia03/crosscript](https://github.com/yqia03/crosscript/security/advisories/new). Private vulnerability reporting is enabled for this repository. Please include the affected version/build, macOS version, workflow/component, impact, minimal reproduction steps and a safe synthetic example if needed. Do not send real API keys, private documents, recordings or unredacted logs.

安全问题请通过 [GitHub 私密漏洞报告](https://github.com/yqia03/crosscript/security/advisories/new)提交，包含受影响版本／build、macOS、组件／工作流、影响、最小复现步骤，必要时使用安全的合成样例。请勿附上真实 API Key、私人文档／录音或未脱敏日志。

If you cannot use that form, open a [public issue](https://github.com/yqia03/crosscript/issues/new) containing only a request for a private reporting channel; omit the vulnerability details and secrets. Ordinary bugs and support questions belong in Issues under [CONTRIBUTING.md](CONTRIBUTING.md).

若无法使用该表单，可提交仅请求私密联系渠道的[公开 issue](https://github.com/yqia03/crosscript/issues/new)，不要包含漏洞细节或凭据。一般 bug 与使用帮助按[贡献指南](CONTRIBUTING.md)反馈。

## Version and response scope / 版本与响应范围

The current published preview is [0.1.0 build 5](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5). Reports affecting this preview or the current source are welcome. No maintained backport branches, response deadline or guaranteed fix window are promised; this is a personally maintained project. A future fix may require a new version. Do not replace or re-sign the frozen release to represent a fix.

当前公开预览版为 [0.1.0 build 5](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5)，欢迎报告影响此版或当前源码的问题。项目由个人维护，不承诺旧版回补分支、响应期限或修复时限。修复可能需要新版本，不能替换或重签冻结发行包来表示已修复。

Build 5 uses ad-hoc integrity signing without Developer ID authentication or Apple notarization. Its second-Mac checks were not run and were waived. These facts are installation/verification limits, not a security audit or a claim of vulnerability absence. Preserve macOS protections and use the [installation guidance](docs/getting-started.md).

build 5 采用 ad-hoc 完整性签名，没有 Developer ID 认证或 Apple 公证；二机检查未执行且已豁免。这些是安装／验证边界，不代表安全审计或不存在漏洞的保证。请保留 macOS 防护，参阅[安装说明](docs/getting-started.zh-CN.md)。
