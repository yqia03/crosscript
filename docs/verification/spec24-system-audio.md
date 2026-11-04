# System and application audio checks for #26

On 2026-11-02, the existing system-audio implementation passed the native checks below on Apple Silicon, macOS 26.6.2. No system-audio product defect was established, so this ticket adds coverage and records evidence without inventing a capture fix. These checks use production recording/session/ScreenCaptureKit objects from the development tree containing #25; they are not packaged-App or release acceptance.

## Native source and lifecycle evidence

Two isolated synthetic applications continuously played 440 Hz and 710 Hz tones. Their identities were resolved through Launch Services, including process and launch time. The final fixtures were accessory apps with one persistent offscreen, alpha-zero, non-key window each; the invariants were checked before use. They were launched without activation and reused, with no visible windows. Windowless accessory apps were not shareable through ScreenCaptureKit and were correctly rejected as unavailable.

A signed native harness exercised the real `RecordingSession` → `SourceRecorder` → `SystemAudioRecorder` path, saved CAF files, reopened history and loaded/played the saved audio. Live delivery used a local PCM receiver. Both the harness and fixtures denied all network access. No provider, credential, user recording, Bluetooth reconnection or system input/output default change was involved.

| Source | Recording and post-recording workflow | Live workflow |
| --- | --- | --- |
| Whole system | 3 repeated cycles; both tones present | 3 repeated cycles; both tones present, local Live PCM delivered |
| Selected application | 3 repeated cycles; selected tone present, other tone below 0.1% | 3 repeated cycles; same isolation, local Live PCM delivered |
| Selected application exits | Confirmed process exit; explicit interruption; prior audio retained and reopened/played | Same result using the other fixture; local Live PCM retained before interruption |

Each normal cycle reused its recorder/session, paused, verified that saved duration and Live byte count stopped growing, resumed with the same selected source, stopped, saved and reopened. After stop, duration and Live byte count remained stable before the next start. All 12 normal cycles and both exit cases passed without a crash. Both fixture processes were absent after cleanup.

Tone magnitudes were measured in 100 ms windows and averaged. A whole-file Fourier magnitude can cancel when pause joins segments with different phases; an initial such assertion was a probe limitation, not evidence of missing captured audio. Early exit attempts without confirming process termination were also inconclusive and are superseded by the confirmed exit checks above.

## Durable offline checks

`SystemAudioSourceTests` exercises the production adapter through both workflow sessions and direct start. Missing processes, mismatched bundle IDs, missing launch times and stale launch times fail without creating audio or history and without falling back to whole-system capture. It does not request ScreenCaptureKit content, open desktop capture or prompt for permission. The two new test functions cover 12 parameter cases.

The bounded offline selection was run under an OS deny-network policy through the existing wrapper:

```sh
bash app/macos/scripts/test.sh --disable-sandbox \
  --scratch-path "$TEST_SCRATCH" -j 2 \
  --filter 'SystemAudioSourceTests|RecordingSessionTests|LiveBilingualSessionTests|LiveAudioConversionTests'
```

Result: 56 core functions in two suites and five native functions in two suites passed. Existing tests cover source locking, session interruption and preserved audio, late permission/start/pause/resume/failure completions, restart identity, paused upload behavior, and separation of local capture from Live conversion/service failures. These controlled tests are distinct from the native source checks above. The added identity coverage passed against existing behavior; there is no claimed product red-to-green fix.

## Remaining boundary

Final integrated actual-App selection, workflow navigation, history and service presentation remain the #33 acceptance step. Local Live PCM delivery does not establish Gemini connectivity or bilingual results. This work did not revoke the real macOS permission grant, disconnect a display, change an output route or induce a physical device failure. Controlled denial/error tests do not substitute for those unexecuted native cases. No release or issue closure is established by this record.
