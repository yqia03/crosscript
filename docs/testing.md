# Testing scope

The snapshot includes both SwiftPM test targets, WorkbenchCoreTests and NativeAudioTests, with their source unchanged. Application behavior is unchanged by the public-file selection. The retained Python tests use synthetic documents, controlled services or isolated tool mocks; source inclusion does not mean they were executed for this release.

Release preparation must select bounded checks that address the changed build and packaging surface. Keep stopped service experiments stopped. Do not run real providers, import private recordings, access actual API credentials or infer a fresh budget from a historical test script. Do not use a full test-suite invocation as an excuse to restart excluded service acceptance.

For a specifically reviewed local test selection, use the existing wrapper and an external scratch/output directory. AppKit UI tests need separate processes. PDF bridge integration needs the exact managed runtime; a skipped runtime-dependent case is not a pass. A deny-network process boundary should cover offline tests and descendants. Some controlled HTTP engine tests require loopback and therefore need a separately reviewed policy; they are not part of deny-all-network regression.

The retained `scripts/dev/run-final-local-regression.py` is the historical full-suite driver. It requires a clean committed source tree, an exact full commit ID, an explicit runtime and a new output directory, and discovers AppKit cases for process isolation. It is retained as build/test source, not authorization to execute every test in this preparation. A scoped release run must record its exact selected tests and omitted scope.

`python3 -B scripts/release/test_package_preview.py` exercises packaging boundaries with synthetic tool outputs. `python3 -B scripts/pdf/test_language_options.py` checks bridge language mapping without downloading a runtime or sending requests. Neither proves provider availability, real installation or whole-stack licensing.

Historical real-service probe applications, private sample manifests and private acceptance logs are excluded from this snapshot. Their absence does not remove any of the four application workflows. See [PDF maintenance](pdf-maintenance.md) for exact retained pins and [synthetic fixtures](../tests/fixtures/pdf/README.md) for authored test data.

System/application audio validation for #26 is recorded in [the focused evidence record](verification/spec24-system-audio.md). The `SystemAudioSourceTests` identity checks are offline and never open desktop capture; real source checks and their remaining actual-App/device boundaries are recorded separately.

Spec #24 candidate consolidation is recorded in [the candidate verification record](verification/spec24-candidate.md). It separates final package identity, actual-App checks, native source harnesses, controlled outputs and unexecuted scope; it does not replace the existing service/release gates.
