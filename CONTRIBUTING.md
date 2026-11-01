# Contributing to Crosscript

Feedback, bug reports and focused pull requests are welcome. This is a personally maintained project; response times are not guaranteed.

Describe the problem, the change and the checks you performed. Keep terminology consistent with [CONTEXT.md](CONTEXT.md), read the relevant requirements and decisions before changing behavior, and include meaningful validation for the change. Do not commit API keys, private recordings, personal documents or unreviewed local outputs.

## Bugs, support and security

Use [GitHub Issues](https://github.com/yqia03/crosscript/issues/new) for bugs, setup questions and feature requests. Include the app version/build, macOS version, chip, workflow, provider/model, expected behavior, actual behavior and minimal reproduction steps. Use original synthetic samples where possible; remove credentials, personal text/audio and machine paths. Do not run paid/provider probes merely to complete a report.

Report vulnerabilities using [GitHub private vulnerability reporting](https://github.com/yqia03/crosscript/security/advisories/new), following [SECURITY.md](SECURITY.md). Do not open a public exploit report or attach secrets. No response or fix deadline is guaranteed.

中文：普通问题、安装帮助和功能建议请提交 [Issue](https://github.com/yqia03/crosscript/issues/new)，包含版本／build、系统与芯片、工作流、服务／模型、预期／实际行为和最小复现步骤。优先使用原创合成样例，去除凭据、私人正文／音频及机器路径。安全问题请用[私密漏洞报告](https://github.com/yqia03/crosscript/security/advisories/new)，不要在公开 issue 披露利用细节。

## Release and validation scope

The published preview is [v0.1.0-preview.5](https://github.com/yqia03/crosscript/releases/tag/v0.1.0-preview.5). Its tag, signed App and 28 assets are frozen. Changes to build-input documentation or code on the development branch apply to future builds; they do not alter build 5. Preserve the distinction between publication approval, actual checks and remaining gaps. Build 5 second-Mac checks were not run and were explicitly waived; no build 4 result may be relabeled as build 5 acceptance.

Read [testing scope](docs/testing.md) before selecting checks. Keep stopped PDF batches and live/paid provider experiments stopped unless separately authorized. Documentation-only changes need relevant link, consistency and privacy checks; they do not need an App rebuild or fabricated runtime acceptance.

## Contribution license

The project's original code is licensed under the **GNU Affero General Public License, version 3 only (`AGPL-3.0-only`)** in [LICENSE](LICENSE), subject to the third-party scope described in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

By intentionally submitting an original code contribution for inclusion in this project, you offer that contribution under AGPL-3.0-only and must have the right to do so. Submission does not transfer copyright; rights remain with their respective copyright holders. No separate CLA or DCO sign-off is required.

For existing third-party material, identify its origin, version and license, preserve its copyright and license notices, and explain any changes. Do not relabel it as original project code or add a commercial-use ban. Compatibility and source/notice obligations must be checked before inclusion; upstream “or later” permissions remain intact.

AGPL-compliant commercial use and redistribution are permitted. Applicable corresponding-source and network-interaction requirements remain governed by the actual license; private local changes do not automatically have to be published to everyone.
