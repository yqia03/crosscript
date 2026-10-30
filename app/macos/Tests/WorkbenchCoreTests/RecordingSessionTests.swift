import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized)
@MainActor
final class RecordingSessionTests {
    private var roots: [URL] = []

    @Test func workflowsKeepSeparateProjectsAndRetainAudioAfterReopening() async throws {
        defer { cleanUp() }
        let store = RecordingStore(root: temporaryRoot())
        let recorder = FakeRecorder()
        let session = RecordingSession(store: store, recorder: recorder)
        await session.start()
        try recorder.receiveAudio("transcription", duration: 2)
        session.stop()
        let transcript = try #require(session.selectedRecording)
        let transcriptAudio = try Data(contentsOf: session.audioURL(for: transcript.id))
        await session.start(workflow: .liveTranslation)
        try recorder.receiveAudio("interpretation", duration: 3)
        session.stop()
        let interpreted = try #require(session.selectedRecording)
        let interpretedAudio = try Data(contentsOf: session.audioURL(for: interpreted.id))
        #expect(interpreted.workflow == .liveTranslation)
        #expect(session.recordings(in: .transcription).map(\.id) == [transcript.id])
        session.activateWorkflow(.transcription)
        #expect(session.selectedID == transcript.id)
        session.newProject()
        session.activateWorkflow(.liveTranslation)
        #expect(session.selectedID == interpreted.id)
        session.activateWorkflow(.transcription)
        session.refresh()
        #expect(session.selectedID == nil)
        let reopened = RecordingSession(store: store, recorder: FakeRecorder())
        #expect(reopened.selectedID == transcript.id)
        reopened.activateWorkflow(.liveTranslation)
        #expect(reopened.selectedID == interpreted.id)
        #expect(try Data(contentsOf: reopened.audioURL(for: transcript.id)) == transcriptAudio)
        #expect(try Data(contentsOf: reopened.audioURL(for: interpreted.id)) == interpretedAudio)
    }

    @Test func legacyBilingualHistoryMigratesItsWorkflowWithoutChangingItsContents() throws {
        defer { cleanUp() }
        let store = RecordingStore(root: temporaryRoot())
        let legacy = Recording(id: UUID(), startedAt: .now, defaultName: "Meeting", name: "Meeting", duration: 4, status: .saved)
        try store.save(legacy)
        let folder = store.audioURL(for: legacy.id).deletingLastPathComponent()
        let metadata = folder.appendingPathComponent("recording.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        json.removeValue(forKey: "workflow")
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        let bilingual = folder.appendingPathComponent("bilingual-results.json")
        let savedResult = Data("{\"version\":1,\"results\":[],\"deletedResultIDs\":[]}".utf8)
        try savedResult.write(to: bilingual)
        let audio = Data("original audio".utf8)
        try audio.write(to: store.audioURL(for: legacy.id))

        let migrated = try #require(store.load().recordings.first)
        #expect(migrated.workflow == .liveTranslation)
        #expect(migrated.id == legacy.id && migrated.name == legacy.name)
        #expect(try Data(contentsOf: bilingual) == savedResult)
        #expect(try Data(contentsOf: store.audioURL(for: legacy.id)) == audio)
        // Workflow survives a later cleanup of the now-empty result journal.
        try FileManager.default.removeItem(at: bilingual)
        #expect(try store.load().recordings.first?.workflow == .liveTranslation)
    }

    private func cleanUp() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    @Test
    func testNewProjectOpensEmptyWorkspaceWithoutCapturingOrChangingHistory() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let store = RecordingStore(root: root)
        let recorder = FakeRecorder()
        let session = RecordingSession(store: store, recorder: recorder)
        session.selectSource(.system)
        await session.start()
        try recorder.receiveAudio("preserved history", duration: 12)
        session.stop()
        let original = try #require(session.selectedRecording)
        var transcription = TranscriptionMaterial()
        transcription.results = [TranscriptResult(id: UUID(), createdAt: .now, model: "saved-model", text: "用户已经编辑的文字。")]
        try store.saveTranscription(transcription, for: original.id)
        let audio = try Data(contentsOf: session.audioURL(for: original.id))
        let historyFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        recorder.permissionWasRequested = false

        session.newProject()

        #expect(session.selectedID == nil)
        #expect(session.selectedRecording == nil)
        #expect(session.elapsed == 0)
        #expect(session.selectedSource == .system)
        #expect(!recorder.permissionWasRequested)
        #expect(!recorder.isCapturing)
        #expect(!session.hasActiveRecording)
        #expect(session.recordings == [original])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == historyFiles)
        #expect(try Data(contentsOf: session.audioURL(for: original.id)) == audio)
        #expect(try store.loadTranscription(for: original.id) == transcription)
        session.refresh()
        #expect(session.selectedID == nil)
        #expect(session.recordings == [original])

        session.select(original.id)
        session.refresh()
        #expect(session.selectedID == original.id)
        let reopened = RecordingSession(store: store, recorder: FakeRecorder())
        #expect(reopened.selectedRecording == original)
    }

    @Test(arguments: ["permission", "recording", "paused", "pendingSave"])
    func testNewProjectCannotDiscardAnActiveCaptureOrUnfinishedCommand(stage: String) async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder)
        await session.start()
        session.stop()
        #expect(session.canCreateProject)
        recorder.waitForPermission = stage == "permission"
        let start = Task { await session.start() }
        if stage == "permission" {
            try await eventually { recorder.permissionContinuation != nil }
        } else {
            await start.value
            try recorder.receiveAudio("active audio must survive", duration: 9)
            if stage == "paused" { await session.pause() }
            if stage == "pendingSave" {
                let id = try #require(session.activeID)
                let metadata = session.audioURL(for: id).deletingLastPathComponent().appendingPathComponent("recording.json")
                try FileManager.default.removeItem(at: metadata)
                try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
                session.stop()
                #expect(session.needsSaveRetry)
            }
        }
        let selectedID = session.selectedID
        let activeID = session.activeID
        let elapsed = session.elapsed
        #expect(!session.canCreateProject)

        session.newProject()

        #expect(session.selectedID == selectedID)
        #expect(session.activeID == activeID)
        #expect(session.elapsed == elapsed)
        if stage == "permission" {
            recorder.permissionContinuation?.resume()
            recorder.permissionContinuation = nil
            await start.value
        }
        session.stop()
    }

    @Test
    func testEmptyProjectImportsOnlyOnRequestAndCannotStartCaptureDuringImport() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: root.appendingPathComponent("Library")), recorder: recorder)
        await session.start()
        session.stop()
        let original = try #require(session.selectedRecording)
        session.newProject()
        await session.importAudio(from: root.appendingPathComponent("unsupported.mp4"), using: ControlledAudioImporter())
        session.refresh()
        #expect(session.selectedID == nil)
        #expect(session.recordings == [original])

        let source = root.appendingPathComponent("new project.wav")
        let bytes = Data("imported project source".utf8)
        try bytes.write(to: source)
        let importer = SuspendedProjectImporter()
        let importing = Task { await session.importAudio(from: source, using: importer) }
        try await eventually { session.isImporting }
        recorder.permissionWasRequested = false
        #expect(!session.canCreateProject)
        session.newProject()
        await session.start()
        #expect(!recorder.permissionWasRequested)
        #expect(!recorder.isCapturing)
        #expect(session.selectedID == nil)
        await importer.finish()
        await importing.value
        let imported = try #require(session.selectedRecording)
        #expect(imported.isImported)
        #expect(imported.name == "new project")
        #expect(session.recordings.count == 2)
        #expect(session.recordings.contains(original))
        #expect(try Data(contentsOf: session.audioURL(for: imported.id)) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        session.refresh()
        #expect(session.selectedID == imported.id)
        session.stop()

        session.newProject()
        recorder.permissionWasRequested = false
        await session.start()
        #expect(recorder.permissionWasRequested)
        #expect(session.isRecording)
        #expect(session.recordings.count == 3)
        #expect(session.activeID != imported.id)
        session.stop()
    }

    @Test
    func testPauseStopsGrowthAndResumeKeepsOneRecordingAndItsIdentity() async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder,
                                       now: { Date(timeIntervalSince1970: 0) }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        session.selectSource(.system)
        await session.start()
        let recording = try #require(session.activeRecording)
        try recorder.receiveAudio("before pause", duration: 3)
        await session.pause()
        #expect(session.isPaused)
        #expect(!session.isRecording)
        #expect(session.activeRecording?.status == .paused)
        #expect(session.elapsed == 3)
        let pausedAudio = try Data(contentsOf: session.audioURL(for: recording.id))
        try recorder.receiveAudio("must not appear", duration: 20)
        #expect(try Data(contentsOf: session.audioURL(for: recording.id)) == pausedAudio)
        session.rename(id: recording.id, name: "  Paused meeting  ")
        #expect(session.activeRecording?.name == "Paused meeting")
        session.rename(id: recording.id, name: " ")
        #expect(session.activeRecording?.name == "1970-01-01 00:00:00")
        session.selectSource(.microphone)
        await session.resume()
        try recorder.receiveAudio("after resume", duration: 2)
        #expect(session.isRecording)
        #expect(!session.isPaused)
        #expect(session.activeID == recording.id)
        #expect(session.activeRecording?.source == .system)
        session.stop()
        #expect(session.recordings.count == 1)
        #expect(session.selectedRecording?.duration == 5)
        #expect(session.selectedRecording?.status == .saved)
        let savedAudio = try Data(contentsOf: session.audioURL(for: recording.id))
        #expect(savedAudio.count > pausedAudio.count)
        #expect(!String(decoding: savedAudio, as: UTF8.self).contains("must not appear"))
    }

    @Test(arguments: [false, true])
    func testActualSleepInterruptsAndPreservesSavedPrefixWithoutResuming(paused: Bool) async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        let root = temporaryRoot()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        session.selectSource(.system)
        await session.start()
        let id = try #require(session.activeID)
        try recorder.receiveAudio("saved before sleep", duration: 7)
        if paused { await session.pause() }
        let before = try Data(contentsOf: session.audioURL(for: id))
        session.systemWillSleep()
        try recorder.receiveAudio("during sleep", duration: 30)
        #expect(!session.isRecording)
        #expect(!session.isPaused)
        #expect(!session.hasActiveRecording)
        #expect(session.selectedRecording?.status == .interrupted)
        #expect(session.selectedRecording?.interruptionReason == .systemSleep)
        #expect(session.selectedRecording?.duration == 7)
        await session.resume()
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.interruptionReason == .systemSleep)
        #expect(reopened.selectedRecording?.source == .system)
        #expect(try Data(contentsOf: reopened.audioURL(for: id)) == before)
    }

    @Test
    func testQuitCancellationKeepsCapturingAndConfirmationRequiresSuccessfulSave() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        #expect(session.requestQuit())
        await session.start()
        let id = try #require(session.activeID)
        #expect(!session.requestQuit())
        #expect(session.quitConfirmationRequired)
        session.cancelQuit()
        #expect(!session.quitConfirmationRequired)
        try recorder.receiveAudio("after cancelled quit", duration: 4)
        #expect(session.isRecording)
        let metadata = session.audioURL(for: id).deletingLastPathComponent().appendingPathComponent("recording.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        #expect(!session.requestQuit())
        #expect(await !session.confirmQuit())
        #expect(!session.isRecording)
        #expect(session.needsSaveRetry)
        #expect(session.selectedRecording?.duration == 4)
        try recorder.receiveAudio("must not recapture", duration: 5)
        try FileManager.default.removeItem(at: metadata)
        #expect(!session.requestQuit())
        #expect(await session.confirmQuit())
        #expect(!session.hasActiveRecording)
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.status == .saved)
        #expect(reopened.selectedRecording?.duration == 4)
        let audio = String(decoding: try Data(contentsOf: reopened.audioURL(for: id)), as: UTF8.self)
        #expect(audio.contains("after cancelled quit"))
        #expect(!audio.contains("must not recapture"))
    }

    @Test(arguments: [RecordingStatus.recording, .paused])
    func testRestartRecoversActualSavedDurationAndReportsUnreadableAudio(status: RecordingStatus) throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let store = RecordingStore(root: root)
        let original = Recording(id: UUID(), startedAt: .now, defaultName: "start", name: "Retained name",
                                 duration: 1, status: status, source: .system)
        try store.save(original)
        let bytes = Data("recoverable saved prefix".utf8)
        try bytes.write(to: store.audioURL(for: original.id))
        let failed = RecordingSession(store: store, recorder: FakeRecorder(), inspectAudioDuration: { _ in throw TestFailure.unavailable })
        #expect(failed.selectedRecording?.status == .interrupted)
        #expect(failed.lastError != nil)
        #expect(try Data(contentsOf: failed.audioURL(for: original.id)) == bytes)
        let recovered = RecordingSession(store: store, recorder: FakeRecorder(), inspectAudioDuration: { url in
            guard try Data(contentsOf: url) == bytes else { throw TestFailure.unavailable }
            return 37.25
        })
        #expect(recovered.selectedRecording?.duration == 37.25)
        #expect(recovered.selectedRecording?.interruptionReason == .unexpectedTermination)
        #expect(recovered.selectedRecording?.name == "Retained name")
        #expect(recovered.selectedRecording?.source == .system)
        #expect(!recovered.isRecording)
        #expect(!recovered.hasActiveRecording)
        #expect(recovered.lastError == nil)
        #expect(try Data(contentsOf: recovered.audioURL(for: original.id)) == bytes)
    }

    @Test(arguments: [false, true])
    func testSleepDuringStartCancelsLateCompletionWithoutCreatingFalseRecording(permissionPending: Bool) async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        recorder.waitForPermission = permissionPending
        recorder.waitForStart = !permissionPending
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder)
        let start = Task { await session.start() }
        try await eventually { permissionPending ? recorder.permissionContinuation != nil : recorder.startContinuation != nil }
        session.systemWillSleep()
        #expect(!session.isRecording)
        if permissionPending {
            recorder.permissionContinuation?.resume()
            recorder.permissionContinuation = nil
        } else {
            recorder.startContinuation?.resume()
            recorder.startContinuation = nil
        }
        await start.value
        #expect(!session.isRecording)
        #expect(!session.isBusy)
        #expect(!session.hasActiveRecording)
        #expect(!recorder.isCapturing)
        if permissionPending {
            #expect(session.recordings.isEmpty)
        } else {
            #expect(session.selectedRecording?.status == .interrupted)
            #expect(session.selectedRecording?.interruptionReason == .systemSleep)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func testEndingDuringPauseOrResumeCannotRestartOrOverwriteSavedRecording(resuming: Bool, sleeping: Bool) async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder)
        await session.start()
        let id = try #require(session.activeID)
        try recorder.receiveAudio("before transition", duration: 9)
        if resuming { await session.pause(); recorder.waitForResume = true }
        else { recorder.waitForPause = true }
        let transition = Task { if resuming { await session.resume() } else { await session.pause() } }
        try await eventually { resuming ? recorder.resumeContinuation != nil : recorder.pauseContinuation != nil }
        #expect(session.isBusy)
        if sleeping { session.systemWillSleep() } else { session.stop() }
        await session.start()
        #expect(session.recordings.count == 1)
        if resuming { recorder.resumeContinuation?.resume(); recorder.resumeContinuation = nil }
        else { recorder.pauseContinuation?.resume(); recorder.pauseContinuation = nil }
        await transition.value
        try recorder.receiveAudio("after ended", duration: 11)
        #expect(!session.isRecording)
        #expect(!session.isPaused)
        #expect(!session.isBusy)
        #expect(!session.hasActiveRecording)
        #expect(!recorder.isCapturing)
        #expect(session.selectedRecording?.status == (sleeping ? .interrupted : .saved))
        #expect(session.selectedRecording?.interruptionReason == (sleeping ? .systemSleep : nil))
        #expect(session.selectedRecording?.duration == 9)
        #expect(!String(decoding: try Data(contentsOf: session.audioURL(for: id)), as: UTF8.self).contains("after ended"))
    }

    @Test(arguments: ["permission", "start", "pause", "resume"])
    func testConfirmedQuitWaitsForOutstandingCaptureCommandToSettle(stage: String) async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder)
        let transition: Task<Void, Never>
        if stage == "permission" || stage == "start" {
            recorder.waitForPermission = stage == "permission"
            recorder.waitForStart = stage == "start"
            transition = Task { await session.start() }
            try await eventually { recorder.permissionContinuation != nil || recorder.startContinuation != nil }
        } else {
            await session.start()
            try recorder.receiveAudio("before quitting", duration: 8)
            if stage == "resume" { await session.pause(); recorder.waitForResume = true }
            else { recorder.waitForPause = true }
            transition = Task { if stage == "resume" { await session.resume() } else { await session.pause() } }
            try await eventually { recorder.pauseContinuation != nil || recorder.resumeContinuation != nil }
        }
        #expect(!session.requestQuit())
        var quitResult: Bool?
        let quit = Task { quitResult = await session.confirmQuit() }
        try await eventually { !session.quitConfirmationRequired }
        #expect(quitResult == nil, "Quit must await the device command before authorizing process exit")
        recorder.permissionContinuation?.resume(); recorder.permissionContinuation = nil
        recorder.startContinuation?.resume(); recorder.startContinuation = nil
        recorder.pauseContinuation?.resume(); recorder.pauseContinuation = nil
        recorder.resumeContinuation?.resume(); recorder.resumeContinuation = nil
        await transition.value
        await quit.value
        #expect(quitResult == true)
        #expect(!session.isBusy)
        #expect(!session.hasActiveRecording)
        #expect(!recorder.isCapturing)
        if stage == "permission" { #expect(session.recordings.isEmpty) }
        else { #expect(session.selectedRecording?.status == .saved) }
    }

    @Test(arguments: [false, true])
    func testCaptureFailureDuringPauseOrResumeRetainsInterruptionAfterLateCompletion(resuming: Bool) async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder)
        await session.start()
        try recorder.receiveAudio("saved prefix", duration: 6)
        if resuming { await session.pause(); recorder.waitForResume = true }
        else { recorder.waitForPause = true }
        let transition = Task { if resuming { await session.resume() } else { await session.pause() } }
        try await eventually { recorder.pauseContinuation != nil || recorder.resumeContinuation != nil }
        recorder.onFailure?(TestFailure.unavailable)
        #expect(session.selectedRecording?.status == .interrupted)
        #expect(!recorder.isCapturing)
        recorder.pauseContinuation?.resume(); recorder.pauseContinuation = nil
        recorder.resumeContinuation?.resume(); recorder.resumeContinuation = nil
        await transition.value
        #expect(!session.hasActiveRecording)
        #expect(!session.isRecording)
        #expect(!session.isPaused)
        #expect(!recorder.isCapturing)
        #expect(session.selectedRecording?.status == .interrupted)
        #expect(session.selectedRecording?.interruptionReason == .captureFailure)
        #expect(session.selectedRecording?.duration == 6)
        #expect(session.lastError != nil)
    }

    @Test
    func testCaptureErrorUsesCurrentInterfaceLanguageWithoutRetrying() async {
        defer { cleanUp() }
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: "interfaceLanguage")
        defer { defaults.set(previousLanguage, forKey: "interfaceLanguage") }
        defaults.set("zhHans", forKey: "interfaceLanguage")
        let recorder = FakeRecorder()
        recorder.permissionError = LanguageDependentFailure.denied
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder)
        session.selectSource(.system)
        await session.start()
        #expect(session.lastError == "音源访问被拒绝。")
        defaults.set("english", forKey: "interfaceLanguage")
        #expect(session.lastError == "Audio source access was denied.")
        defaults.set("zhHans", forKey: "interfaceLanguage")
        #expect(session.lastError == "音源访问被拒绝。")
        defaults.set("system", forKey: "interfaceLanguage")
        let systemMessage = Locale.preferredLanguages.first?.hasPrefix("zh") == true
            ? "音源访问被拒绝。" : "Audio source access was denied."
        #expect(session.lastError == systemMessage)
        #expect(!(session.isRecording))
        #expect(session.recordings.isEmpty)
        session.dismissError()
        #expect(session.lastError == nil)
    }

    @Test
    func testInterruptedCaptureAndPendingSaveErrorsUpdateLanguageTogether() async throws {
        defer { cleanUp() }
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: "interfaceLanguage")
        defer { defaults.set(previousLanguage, forKey: "interfaceLanguage") }
        defaults.set("zhHans", forKey: "interfaceLanguage")
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        session.selectSource(.system)
        await session.start()
        let id = try #require(session.activeID)
        let material = session.audioURL(for: id).deletingLastPathComponent()
        let metadata = material.appendingPathComponent("recording.json")
        try FileManager.default.moveItem(at: metadata, to: material.appendingPathComponent("metadata-backup"))
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        recorder.onFailure?(LanguageDependentFailure.denied)
        #expect(session.needsSaveRetry)
        #expect(session.selectedRecording?.status == .interrupted)
        #expect(session.lastError?.hasPrefix("音源访问被拒绝。\n录音已停止，但录音信息尚未保存。请重试保存。\n") == true)
        defaults.set("english", forKey: "interfaceLanguage")
        #expect(session.lastError?.hasPrefix("Audio source access was denied.\nThe audio has stopped, but its recording details could not be saved. Retry saving.\n") == true)
        try FileManager.default.removeItem(at: metadata)
        session.stop()
        #expect(!(session.needsSaveRetry))
        #expect(session.lastError == nil)
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.status == .interrupted)
        #expect(reopened.selectedRecording?.source == .system)
    }

    @Test
    func testSystemSourceRemainsWithSavedRecordingAfterRenameAndReopen() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        session.selectSource(.system)
        await session.start()
        let recording = try #require(session.activeRecording)
        #expect(recording.source == .system)
        session.rename(id: recording.id, name: "Video meeting")
        session.stop()
        session.selectSource(.microphone)
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.source == .system)
        #expect(reopened.selectedRecording?.name == "Video meeting")
    }

    @Test
    func testApplicationSourceIsLockedWhilePermissionAndCaptureAreInProgress() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        recorder.waitForPermission = true
        let source = AudioSource.application(AudioApplication(bundleIdentifier: "com.example.Player", name: "Video player", processID: 42, launchDate: Date(timeIntervalSince1970: 100)))
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        session.selectSource(source)
        let start = Task { await session.start() }
        try await eventually { recorder.permissionContinuation != nil }
        session.selectSource(.microphone)
        #expect(session.selectedSource == source)
        recorder.permissionContinuation?.resume()
        recorder.permissionContinuation = nil
        await start.value
        #expect(session.activeRecording?.source == source)
        session.selectSource(.system)
        #expect(session.selectedSource == source)
        #expect(session.activeRecording?.source == source)
        session.stop()
        session.selectSource(.microphone)
        #expect(session.selectedSource == .microphone)
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.source == source)
    }

    @Test
    func testLegacyMicrophoneRecordingReopensWithoutChangingItsAudio() throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let id = UUID()
        let material = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: material, withIntermediateDirectories: true)
        let audio = material.appendingPathComponent("audio.caf")
        let originalAudio = Data("retained T1 recording".utf8)
        try originalAudio.write(to: audio)
        let legacyMetadata = Data("""
        {"id":"\(id.uuidString)","startedAt":0,"defaultName":"2001-01-01 08:00:00","name":"T1 recording","duration":3,"status":"saved"}
        """.utf8)
        try legacyMetadata.write(to: material.appendingPathComponent("recording.json"))
        let session = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(session.selectedRecording?.id == id)
        #expect(session.selectedRecording?.source == .microphone)
        #expect(session.lastError == nil)
        session.rename(id: id, name: "Old recording")
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.source == .microphone)
        #expect(reopened.selectedRecording?.name == "Old recording")
        #expect(try Data(contentsOf: reopened.audioURL(for: id)) == originalAudio)
    }

    @Test
    func testLateFailureFromPreviousSourceDoesNotInterruptNewRecording() async throws {
        defer { cleanUp() }
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: recorder)
        await session.start()
        let first = try #require(session.activeID)
        let previousFailure = try #require(recorder.onFailure)
        session.stop()
        session.selectSource(.system)
        await session.start()
        let current = try #require(session.activeID)
        previousFailure(TestFailure.unavailable)
        #expect(session.isRecording)
        #expect(session.activeID == current)
        #expect(session.activeRecording?.source == .system)
        #expect(session.lastError == nil)
        #expect(session.recordings.first(where: { $0.id == first })?.status == .saved)
        session.stop()
    }

    @Test
    func testFailureDuringAsyncStartRetainsInterruptedSourceAndCanRetry() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        recorder.waitForStart = true
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        session.selectSource(.system)
        let start = Task { await session.start() }
        try await eventually { recorder.startContinuation != nil }
        recorder.currentTime = 1.25
        recorder.onFailure?(TestFailure.unavailable)
        recorder.startContinuation?.resume()
        recorder.startContinuation = nil
        await start.value
        #expect(!(session.isRecording))
        #expect(!(session.hasActiveRecording))
        #expect(!(session.isBusy))
        #expect(session.lastError != nil)
        let interrupted = try #require(session.selectedRecording)
        #expect(interrupted.status == .interrupted)
        #expect(interrupted.source == .system)
        #expect(interrupted.duration == 1.25)
        #expect(session.elapsed == 1.25)
        let audioBefore = try Data(contentsOf: session.audioURL(for: interrupted.id))
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.source == .system)
        #expect(reopened.selectedRecording?.status == .interrupted)
        #expect(try Data(contentsOf: reopened.audioURL(for: interrupted.id)) == audioBefore)
        recorder.waitForStart = false
        await session.start()
        #expect(session.isRecording)
        #expect(session.activeRecording?.source == .system)
        session.stop()
    }

    @Test
    func testStartStopRenameAndReopenPreservesAudioAndStartTimeName() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        let store = RecordingStore(root: root)
        let session = RecordingSession(store: store, recorder: recorder, now: { Date(timeIntervalSince1970: 0) }, timeZone: { TimeZone(secondsFromGMT: 8 * 3600)! })
        await session.start()
        let active = try #require(session.activeRecording)
        #expect(active.name == "1970-01-01 08:00:00")
        #expect(session.isRecording)
        let originalAudio = try Data(contentsOf: session.audioURL(for: active.id))
        session.rename(id: active.id, name: "  Team meeting  ")
        #expect(session.activeRecording?.name == "Team meeting")
        recorder.currentTime = 12.75
        session.stop()
        #expect(!(session.isRecording))
        #expect(!(session.hasActiveRecording))
        #expect(session.selectedRecording?.status == .saved)
        #expect(session.selectedRecording?.duration == 12.75)

        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder(), now: { Date(timeIntervalSince1970: 99999) }, timeZone: { TimeZone(secondsFromGMT: -8 * 3600)! })
        #expect(reopened.recordings.count == 1)
        #expect(reopened.selectedRecording?.name == "Team meeting")
        reopened.rename(id: active.id, name: " \n\t ")
        #expect(reopened.selectedRecording?.name == "1970-01-01 08:00:00")
        #expect(try Data(contentsOf: reopened.audioURL(for: active.id)) == originalAudio)
    }

    @Test
    func testNewRecordingUsesTimeZoneAtStartWhileOlderNamesStayFixed() async throws {
        defer { cleanUp() }
        var localTimeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: FakeRecorder(), now: { Date(timeIntervalSince1970: 0) }, timeZone: { localTimeZone })
        await session.start()
        let first = try #require(session.activeRecording)
        #expect(first.name == "1970-01-01 08:00:00")
        session.stop()

        // Simulate the time-zone boundary without changing the Mac's settings.
        localTimeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        await session.start()
        let second = try #require(session.activeRecording)
        #expect(second.name == "1969-12-31 16:00:00")
        #expect(session.recordings.first(where: { $0.id == first.id })?.name == "1970-01-01 08:00:00")
        session.stop()
        session.rename(id: first.id, name: " ")
        #expect(session.recordings.first(where: { $0.id == first.id })?.name == "1970-01-01 08:00:00")
    }

    @Test(arguments: [AudioSource.microphone, .system])
    func testPermissionDenialCreatesNoMaterialOrFalseRecording(source: AudioSource) async {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        recorder.permissionError = TestFailure.denied
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        session.selectSource(source)
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
        await session.start()
        #expect(!(session.isRecording))
        #expect(!(session.isBusy))
        #expect(session.recordings.isEmpty)
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
        #expect(session.lastError != nil)
        #expect(session.selectedSource == source)
        recorder.permissionError = nil
        await session.start()
        #expect(session.isRecording)
        #expect(session.activeRecording?.source == source)
        session.stop()
    }

    @Test
    func testStartTimeIsCapturedAfterPermissionAndDoubleSubmissionIsIgnored() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        recorder.waitForPermission = true
        var clock = Date(timeIntervalSince1970: 0)
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder, now: { clock }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        let first = Task { await session.start() }
        try await eventually { recorder.permissionContinuation != nil }
        #expect(session.isBusy)
        #expect(session.recordings.isEmpty)
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
        await session.start()
        clock = Date(timeIntervalSince1970: 100)
        recorder.permissionContinuation?.resume()
        recorder.permissionContinuation = nil
        await first.value
        #expect(session.recordings.count == 1)
        #expect(session.activeRecording?.name == "1970-01-01 00:01:40")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        session.stop()
    }

    @Test
    func testEngineStartFailureNeverBecomesSavedRecording() async {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        recorder.startError = TestFailure.unavailable
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        let source = AudioSource.application(AudioApplication(bundleIdentifier: "com.example.Player", name: "Video player", processID: 42, launchDate: nil))
        session.selectSource(source)
        await session.start()
        #expect(!(session.isRecording))
        #expect(!(session.hasActiveRecording))
        #expect(!(session.isBusy))
        #expect(session.recordings.isEmpty)
        #expect(session.lastError != nil)
        #expect(session.selectedSource == source)
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.recordings.isEmpty)
        recorder.startError = nil
        await session.start()
        #expect(session.activeRecording?.source == source)
        session.stop()
    }

    @Test
    func testStorageUnavailableDoesNotStartCaptureAndCanRetry() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        try Data("occupied".utf8).write(to: root)
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        await session.start()
        #expect(!(recorder.isCapturing))
        #expect(!(session.isRecording))
        #expect(session.recordings.isEmpty)
        #expect(session.lastError != nil)
        try FileManager.default.removeItem(at: root)
        await session.start()
        #expect(session.isRecording)
        session.stop()
    }

    @Test
    func testStoppedAudioSaveFailureRemainsStoppedAndRetriesWithoutRecapturing() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        let source = AudioSource.application(AudioApplication(bundleIdentifier: "com.example.Player", name: "Video player", processID: 42, launchDate: Date(timeIntervalSince1970: 100)))
        session.selectSource(source)
        await session.start()
        let id = try #require(session.activeID)
        let audioURL = session.audioURL(for: id)
        let audioBefore = try Data(contentsOf: audioURL)
        let metadata = audioURL.deletingLastPathComponent().appendingPathComponent("recording.json")
        let backup = audioURL.deletingLastPathComponent().appendingPathComponent("metadata-backup")
        try FileManager.default.moveItem(at: metadata, to: backup)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        recorder.currentTime = 42
        session.stop()
        #expect(!(recorder.isCapturing))
        #expect(!(session.isRecording))
        #expect(session.needsSaveRetry)
        #expect(session.hasActiveRecording)
        #expect(session.selectedRecording?.duration == 42)
        #expect(session.selectedRecording?.status == .saved)
        session.selectSource(.system)
        #expect(session.selectedSource == source)
        #expect(session.selectedRecording?.source == source)
        await session.start()
        #expect(!(recorder.isCapturing))
        #expect(session.recordings.count == 1)
        try FileManager.default.removeItem(at: metadata)
        session.stop()
        #expect(!(session.needsSaveRetry))
        #expect(!(session.hasActiveRecording))
        #expect(session.lastError == nil)
        #expect(try Data(contentsOf: audioURL) == audioBefore)
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.duration == 42)
        #expect(reopened.selectedRecording?.status == .saved)
        #expect(reopened.selectedRecording?.source == source)
    }

    @Test
    func testEngineFailureStopsAndRetainsInterruptedAudio() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let recorder = FakeRecorder()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: recorder)
        let source = AudioSource.application(AudioApplication(bundleIdentifier: "com.example.Player", name: "Video player", processID: 42, launchDate: Date(timeIntervalSince1970: 100)))
        session.selectSource(source)
        await session.start()
        let id = try #require(session.activeID)
        recorder.currentTime = 9
        recorder.onFailure?(TestFailure.unavailable)
        #expect(!(session.isRecording) , "An engine failure must settle before a subsequent start command")
        #expect(!(recorder.isCapturing))
        #expect(session.selectedRecording?.status == .interrupted)
        #expect(session.selectedRecording?.duration == 9)
        #expect(session.selectedRecording?.source == source)
        #expect(session.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: session.audioURL(for: id).path))
        let reopened = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        #expect(reopened.selectedRecording?.status == .interrupted)
        #expect(reopened.selectedRecording?.source == source)
        await session.start()
        #expect(session.isRecording)
        #expect(session.activeID != id)
        #expect(session.activeRecording?.source == source)
        session.stop()
    }

    @Test
    func testSelectingHistoryDoesNotChangeActiveRecording() async throws {
        defer { cleanUp() }
        let session = RecordingSession(store: RecordingStore(root: temporaryRoot()), recorder: FakeRecorder())
        await session.start()
        let first = try #require(session.activeID)
        session.stop()
        session.selectSource(.system)
        await session.start()
        let second = try #require(session.activeID)
        session.select(first)
        #expect(session.selectedID == first)
        #expect(session.activeID == second)
        #expect(session.isRecording)
        #expect(session.selectedSource == .system)
        #expect(session.activeRecording?.source == .system)
        #expect(session.selectedRecording?.source == .microphone)
        session.refresh()
        #expect(session.activeID == second)
        session.stop()
    }

    @Test
    func testUnfinishedMetadataReopensAsInterruptedNotRecording() throws {
        defer { cleanUp() }
        let store = RecordingStore(root: temporaryRoot())
        let unfinished = Recording(id: UUID(), startedAt: .now, defaultName: "start", name: "named", duration: 10, status: .recording)
        try store.save(unfinished)
        try Data("saved prefix".utf8).write(to: store.audioURL(for: unfinished.id))
        let session = RecordingSession(store: store, recorder: FakeRecorder())
        #expect(session.selectedRecording?.status == .interrupted)
        #expect(!(session.isRecording))
        #expect(!(session.hasActiveRecording))
        #expect(session.selectedRecording?.name == "named")
        #expect(try store.load().recordings.first?.status == .interrupted)
    }

    @Test
    func testCorruptEntryIsReportedWithoutDeletingItOrHidingHealthyHistory() async throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let session = RecordingSession(store: RecordingStore(root: root), recorder: FakeRecorder())
        await session.start()
        session.stop()
        let broken = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        let corrupt = broken.appendingPathComponent("recording.json")
        let bytes = Data("not valid metadata".utf8)
        try bytes.write(to: corrupt)
        session.refresh()
        #expect(session.recordings.count == 1)
        #expect(session.lastError != nil)
        #expect(try Data(contentsOf: corrupt) == bytes)
    }

    @Test
    func testSymlinkedMaterialCannotWriteOutsideOwnedRoot() throws {
        defer { cleanUp() }
        let root = temporaryRoot()
        let outside = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let id = UUID()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(id.uuidString), withDestinationURL: outside)
        let record = Recording(id: id, startedAt: .now, defaultName: "time", name: "name", duration: 0, status: .recording)
        #expect(throws: (any Error).self) { try RecordingStore(root: root).save(record) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-core-test-\(UUID().uuidString)", isDirectory: true)
        roots.append(url)
        return url
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "Asynchronous application state did not settle")
    }
}

private enum TestFailure: LocalizedError {
    case denied, unavailable
    var errorDescription: String? { self == .denied ? "Microphone permission denied" : "Recording device unavailable" }
}

private actor SuspendedProjectImporter: AudioImporting {
    private var finished = false
    func copyAudio(from source: URL, to destination: URL) async throws -> TimeInterval {
        while !finished { await Task.yield() }
        try FileManager.default.copyItem(at: source, to: destination)
        return 12
    }
    func finish() { finished = true }
}

private enum LanguageDependentFailure: LocalizedError {
    case denied
    var errorDescription: String? {
        AppLanguage.current.text("音源访问被拒绝。", "Audio source access was denied.")
    }
}

@MainActor private final class FakeRecorder: AudioRecording {
    var currentTime: TimeInterval = 0
    var power: Float = -20
    var onFailure: ((Error) -> Void)?
    var permissionError: Error?
    var permissionWasRequested = false
    var startError: Error?
    var waitForPermission = false
    var permissionContinuation: CheckedContinuation<Void, Error>?
    var waitForStart = false
    var startContinuation: CheckedContinuation<Void, Error>?
    var waitForPause = false
    var waitForResume = false
    var pauseContinuation: CheckedContinuation<Void, Error>?
    var resumeContinuation: CheckedContinuation<Void, Error>?
    private(set) var isCapturing = false
    private var audioURL: URL?

    func requestPermission(for source: AudioSource) async throws {
        permissionWasRequested = true
        if let permissionError { throw permissionError }
        if waitForPermission {
            try await withCheckedThrowingContinuation { permissionContinuation = $0 }
        }
    }

    func start(at url: URL, source: AudioSource) async throws {
        if let startError { throw startError }
        try Data("test audio sample bytes".utf8).write(to: url)
        currentTime = 0
        audioURL = url
        isCapturing = true
        if waitForStart {
            try await withCheckedThrowingContinuation { startContinuation = $0 }
        }
    }

    func pause() async throws {
        if waitForPause { try await withCheckedThrowingContinuation { pauseContinuation = $0 } }
        isCapturing = false
    }
    func resume() async throws {
        if waitForResume { try await withCheckedThrowingContinuation { resumeContinuation = $0 } }
        isCapturing = true
    }

    func receiveAudio(_ text: String, duration: TimeInterval) throws {
        guard isCapturing, let audioURL else { return }
        let handle = try FileHandle(forWritingTo: audioURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        currentTime += duration
    }

    func stop() -> TimeInterval {
        let captured = currentTime
        isCapturing = false
        currentTime = 0
        return captured
    }
}
