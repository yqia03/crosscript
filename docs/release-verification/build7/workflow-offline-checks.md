# Offline workflow checks

**Date:** 2026-11-02  
**Classification:** controlled candidate-local acceptance evidence for selected workflow boundaries related to #16 and #17. This report does not close either issue.

## Source binding

- Checkout: `483db937c7e34431bdc2b3b70dd9c440d2ba5129`
- Build input: `4579cac20caafdd4dc716def209cb21b8b100a66`
- The `app` tree is identical between those revisions (`git diff --exit-code ... -- app` returned 0).
- Configuration: Release. A fresh scratch build was used.

## Results

The first attempt stopped before build/test execution because the tool sandbox denied `sandbox-exec` initialization (`sandbox_apply: Operation not permitted`). A local permission escalation allowed the same commands to run in a fresh directory while retaining `deny network*`; no network boundary was removed.

- Release build and test listing succeeded. Listing is a build/setup action, not a test result.
- **118 selected Swift test functions passed:** 79 core functions, 32 native boundary functions, and 7 isolated AppKit functions. The full selected function inventory, including parameterized function identities, is in [workflow-offline-checks.json](workflow-offline-checks.json). Counts are function identities; parameterized functions can execute multiple cases.
- **4 Python language-option tests passed.**
- All selected commands ran with network access denied. No cloud requests or physical audio capture occurred. Selected tests used fake credentials, `URLProtocol`, and native fixtures; no real Keychain operation was performed.

## Exclusions and limits

`PDFBridgeProcessTests/pythonImportsLeaveBridgeResourcesUnchanged` was omitted because `WORKBENCH_PDF_RUNTIME` was absent and no exact verified managed runtime was supplied. Gemini live/repair, live bilingual session, runtime installer/preparation suites, and three real-Keychain functions were also excluded.

This is local evidence for selected #16/#17 behavior only. It does not establish a real App cloud workflow, runtime-dependent PDF import or rendering, #18/#19, or complete acceptance of #16/#17. It cannot close #16 or #17. No test or application source files were modified.

## Subsequent real-service preflight

The maintainer subsequently approved the bounded US$2.03 execution plan. The first T1 action in the frozen App remained in macOS Keychain authorization: no provider-history entry or provider request was created. At an observed 139.983 seconds, the planned 120-second observation limit had been exceeded; Stop was then invoked and the UI returned to idle. This is a missed observation deadline, not a passing real-service result. Computer Use explicitly disallowed the system SecurityAgent surface, so the task requested manual one-time authorization and stopped all further cloud actions. No secret is included here and the two-request DeepSeek allowance has not been consumed.

Gemini's connection-specific network interruption is also not ready: read-only inspection could not access PF state without an administrator password. No firewall, network, account or security setting was changed. A safe isolated environment or verified existing scoped facility is required before the long-session fault step. These execution prerequisites do not reopen #15 or invalidate the completed local checks.

## Log integrity

SHA-256 digests for the build/list, test, and Python logs are recorded in the JSON report. The original logs and machine-specific execution evidence remain outside this public report.
