import AppKit
import Combine
import SwiftUI
import WorkbenchCore

private typealias AppReferenceState<Value> = SwiftUI.State<Value>

@main
@MainActor
struct TranslationWorkbenchApp: App {
    @StateObject private var session: RecordingSession
    @StateObject private var repair: TranscriptRepairSession
    private let repairObservation: AnyCancellable
    @StateObject private var processing: PostRecordingSession
    @StateObject private var providers: ProviderConfigurationSession
    @StateObject private var translation: TextTranslationSession
    @StateObject private var pdf: PDFTranslationSession
    @StateObject private var pdfRuntime: PDFRuntimePreparationSession
    @AppReferenceState private var bilingual: BilingualSessionState
    @StateObject private var geminiSettings: GeminiLiveSettings
    @StateObject private var bilingualLive: LiveBilingualSession
    @StateObject private var bilingualRecovery: BilingualDraftRecoveryController
    @StateObject private var bilingualRepair: BilingualRepairSession
    private let bilingualStore: BilingualResultStore
    @StateObject private var legacyRecovery: LegacyTranscriptionRecoveryController
    @StateObject private var resources: TranslationResourceLibrary
    // Keep the player alive without making every Scene observe its 10 Hz clock.
    @AppReferenceState private var playback = PlaybackController()
    @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("interfaceLanguage") private var language = "system"
    @FocusedValue(\.newProjectCommand) private var contextualNewProject

    init() {
        #if WORKBENCH_LOCAL_ACCEPTANCE
        let root = FinalAcceptanceEnvironment.requireIsolatedRoot()
        let audioCredentials: any AudioCredentials = FinalAcceptanceEnvironment.audioCredentials
        let recorder: any AudioRecording = FinalAcceptanceEnvironment.recorder
        let bilingualTranslator: any LiveBilingualTranslating = FinalAcceptanceEnvironment.makeLiveTranslator()
        let fileTranscriber: any FileTranscribing = FinalAcceptanceFileTranscriber()
        let intervalTranscriber: any IntervalTranscribing = FinalAcceptanceFileTranscriber()
        let bilingualRepairer: any BilingualIntervalRepairing = FinalAcceptanceEnvironment.makeBilingualRepairer()
        let providerCredentials: any ProviderCredentials = FinalAcceptanceEnvironment.providerCredentials
        let providerChecker: any ProviderConnectionChecking = FinalAcceptanceProviderChecker()
        let textTranslator: any TextTranslating = FinalAcceptanceEnvironment.makeTextTranslator()
        let textStore = FinalAcceptanceEnvironment.makeTextStore(root: root)
        let pdfTranslator: any PDFTranslating = FinalAcceptancePDFTranslator(underlying: .managed(dataRoot: root))
        let runtimePreparer: any PDFRuntimePreparing = FinalAcceptanceRuntimePreparer(root: root)
        #else
        let root = LaunchOptions.dataDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("TranslationWorkbench/Recordings", isDirectory: true)
        let audioCredentials: any AudioCredentials = KeychainAudioCredentials()
        let recorder: any AudioRecording = SourceRecorder()
        let bilingualTranslator: any LiveBilingualTranslating = GeminiLiveTranslator()
        let fileTranscriber: any FileTranscribing = OpenAIFileTranscriber()
        let intervalTranscriber: any IntervalTranscribing = FileIntervalTranscriber()
        let bilingualRepairer: any BilingualIntervalRepairing = GeminiBilingualIntervalRepairer(capabilityAllowsRepair: true)
        let providerCredentials: any ProviderCredentials = KeychainProviderCredentials()
        let providerChecker: any ProviderConnectionChecking = ProviderModelDirectoryChecker()
        let textTranslator: any TextTranslating = OpenAITextTranslator()
        let textStore = TextWorkspaceStore(root: root)
        let pdfTranslator: any PDFTranslating = BabelDOCPDFTranslator.managed(dataRoot: root)
        let runtimePreparer: any PDFRuntimePreparing = PDFRuntimeInstaller(dataRoot: root)
        #endif
        let activity = RecordingActivity()
        let store = RecordingStore(root: root)
        let bilingualStore = BilingualResultStore(recordings: store)
        self.bilingualStore = bilingualStore
        let bilingual = BilingualSessionState { try bilingualStore.publish($0) }
        _bilingual = AppReferenceState(initialValue: bilingual)
        _geminiSettings = StateObject(wrappedValue: GeminiLiveSettings(credentials: audioCredentials))
        WorkbenchAppDelegate.bilingual = bilingual
        let session = RecordingSession(store: store, recorder: recorder,
                                       inspectAudioDuration: AudioFileInspection.duration(at:),
                                       captureActivity: activity.setActive)
        _session = StateObject(wrappedValue: session)
        let bilingualDrafts = BilingualDraftStore(recordings: store)
        _bilingualRecovery = StateObject(wrappedValue: BilingualDraftRecoveryController(drafts: bilingualDrafts, recordings: session, results: bilingualStore))
        let bilingualLive = LiveBilingualSession(recordings: session, credentials: audioCredentials,
            service: bilingualTranslator, presentation: bilingual, drafts: bilingualDrafts)
        _bilingualLive = StateObject(wrappedValue: bilingualLive)
        WorkbenchAppDelegate.bilingualLive = bilingualLive
        let gate = BackgroundProcessingGate()
        WorkbenchAppDelegate.backgroundGate = gate
        let processing = PostRecordingSession(recordings: session, store: store, credentials: audioCredentials, service: fileTranscriber, gate: gate)
        _processing = StateObject(wrappedValue: processing)
        let repair = TranscriptRepairSession(recordings: session, processing: processing,
            store: TranscriptRepairStore(recordings: store), credentials: audioCredentials,
            service: intervalTranscriber, gate: gate)
        _repair = StateObject(wrappedValue: repair)
        let bilingualRepair = BilingualRepairSession(recordings: session, results: bilingualStore,
            journal: BilingualRepairStore(recordings: store), credentials: audioCredentials,
            service: bilingualRepairer, gate: gate)
        _bilingualRepair = StateObject(wrappedValue: bilingualRepair)
        WorkbenchAppDelegate.bilingualRepair = bilingualRepair
        processing.relatedOperationBlocksDeletion = { [weak repair, weak bilingual, weak bilingualRepair] id in
            repair?.occupiesMaterial(id) == true || bilingualRepair?.occupiesMaterial(id) == true || bilingual?.hasUnsavedHistoryEdits(for: id) == true
                || (bilingual?.result?.recordingID == id && bilingual?.canReplaceResult == false)
        }
        processing.didDeleteMaterial = { [weak bilingual] id in bilingual?.forgetMaterial(id) }
        repairObservation = repair.objectWillChange.merge(with: bilingual.objectWillChange).merge(with: bilingualRepair.objectWillChange)
            // objectWillChange fires before the mutation. Recheck the actual deletion
            // boundary afterwards and avoid invalidating unrelated pages for text deltas.
            .receive(on: RunLoop.main)
            .map { [weak session, weak processing] _ in
                session?.recordings.compactMap { recording in
                    processing?.relatedOperationBlocksDeletion(recording.id) == true ? recording.id : nil
                } ?? []
            }
            .removeDuplicates()
            .sink { [weak processing] _ in processing?.objectWillChange.send() }
        WorkbenchAppDelegate.repair = repair
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root),
            credentials: providerCredentials, checker: providerChecker)
        #if WORKBENCH_LOCAL_ACCEPTANCE
        FinalAcceptanceEnvironment.seedProviders(providers)
        #endif
        _providers = StateObject(wrappedValue: providers)
        WorkbenchAppDelegate.providers = providers
        let translation = TextTranslationSession(store: textStore,
            credentials: providerCredentials, service: textTranslator)
        _translation = StateObject(wrappedValue: translation)
        let resources = TranslationResourceLibrary(root: root)
        _resources = StateObject(wrappedValue: resources)
        let legacyDrafts = LegacyTranscriptionRecovery(recordings: store)
        _legacyRecovery = StateObject(wrappedValue: LegacyTranscriptionRecoveryController(drafts: legacyDrafts, recordings: session, processing: processing))
        let pdf = PDFTranslationSession(store: PDFMaterialStore(root: root), credentials: providerCredentials, engine: pdfTranslator, gate: gate)
        _pdf = StateObject(wrappedValue: pdf)
        let pdfRuntime = PDFRuntimePreparationSession(preparer: runtimePreparer)
        _pdfRuntime = StateObject(wrappedValue: pdfRuntime)
        WorkbenchAppDelegate.pdfRuntime = pdfRuntime
        WorkbenchAppDelegate.pdf = pdf
        WorkbenchAppDelegate.resources = resources
        WorkbenchAppDelegate.session = session
        WorkbenchAppDelegate.processing = processing
        WorkbenchAppDelegate.translation = translation
    }

    var body: some Scene {
        Window(appTitle, id: "workbench") {
            WorkbenchView(session: session, playback: playback, processing: processing,
                providers: providers, translation: translation, resources: resources, pdf: pdf, pdfRuntime: pdfRuntime, legacyRecovery: legacyRecovery, repair: repair,
                bilingual: bilingual, bilingualStore: bilingualStore, bilingualRepair: bilingualRepair, geminiSettings: geminiSettings,
                bilingualLive: bilingualLive, bilingualRecovery: bilingualRecovery, openCaptions: { openWindow(id: "bilingual-captions") })
                .frame(minWidth: 680, minHeight: 620)
                .preferredColorScheme(.light)
                #if WORKBENCH_LOCAL_ACCEPTANCE
                .safeAreaInset(edge: .top) { FinalAcceptanceBanner() }
                #endif
                .onAppear {
                    let open = openWindow
                    delegate.openMainWindow = { open(id: "workbench") }
                }
        }
        .defaultSize(width: LaunchOptions.width, height: LaunchOptions.height)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(uiText("许可证与第三方声明…", "License and third-party notices…")) {
                    LicenseNotices.show()
                }
                Button(uiText("显示组件声明文件", "Show component notice files")) {
                    LicenseNotices.revealComponentNotices()
                }
            }
            #if WORKBENCH_LOCAL_ACCEPTANCE
            FinalAcceptanceCommands()
            #endif
            CommandGroup(replacing: .newItem) {
                Button(uiText("新建项目", "New project")) {
                    guard canCreateNewProject else { return }
                    if let contextualNewProject { contextualNewProject.perform(); return }
                    playback.stop()
                    session.activateWorkflow(.transcription)
                    session.newProject()
                    NotificationCenter.default.post(name: .showCurrentRecording, object: nil)
                    openWindow(id: "workbench")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!canCreateNewProject)
                Button(uiText("开始录音", "Start recording")) {
                    playback.stop()
                    Task { await session.start() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!recordingActions.canStart)
                Button(uiText("停止并保存", "Stop and save")) { Task { await recordingActions.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!session.hasActiveRecording || session.isBusy)
                Button(recordingActions.isFinishingPause ? uiText("暂停收尾中…", "Finishing pause…") : session.isPaused ? uiText("继续录音", "Resume recording") : uiText("暂停录音", "Pause recording")) {
                    Task { await recordingActions.togglePause() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!recordingActions.canTogglePause)
            }
        }
        Window(uiText("置顶字幕", "Captions"), id: "bilingual-captions") {
            BilingualCaptionView(state: bilingual, recordings: session, live: bilingualLive)
                .background(BilingualCaptionWindowLevel())
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 720, height: 320)
        MenuBarExtra {
            RecordingMenu(session: session, playback: playback, bilingualLive: bilingualLive)
        } label: {
            RecordingMenuLabel(session: session, telemetry: session.telemetry, language: AppLanguage(preference: language))
        }
        .menuBarExtraStyle(.menu)
    }

    private var canCreateNewProject: Bool {
        NSApp.modalWindow == nil && NSApp.keyWindow?.sheetParent == nil && NSApp.keyWindow?.attachedSheet == nil
            && (contextualNewProject?.isEnabled ?? recordingActions.canStart)
    }
    private var recordingActions: RecordingActions { .init(recordings: session, bilingual: bilingualLive) }

    private var appTitle: String {
        #if WORKBENCH_LOCAL_ACCEPTANCE
        return "本地受控验收 / Local controlled acceptance"
        #else
        return "Crosscript"
        #endif
    }
    private func uiText(_ zh: String, _ en: String) -> String {
        AppLanguage(preference: language).text(zh, en)
    }
}

private enum LaunchOptions {
    static func value(after key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    static var dataDirectory: URL? {
        value(after: "--data-directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var width: CGFloat { CGFloat(Double(value(after: "--window-width") ?? "1280") ?? 1280) }
    static var height: CGFloat { CGFloat(Double(value(after: "--window-height") ?? "900") ?? 900) }
}

@MainActor
final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
    static weak var backgroundGate: BackgroundProcessingGate?
    static weak var session: RecordingSession?
    static weak var processing: PostRecordingSession?
    static weak var providers: ProviderConfigurationSession?
    static weak var repair: TranscriptRepairSession?
    static weak var translation: TextTranslationSession?
    static weak var resources: TranslationResourceLibrary?
    static weak var bilingual: BilingualSessionState?
    static weak var bilingualLive: LiveBilingualSession?
    static weak var bilingualRepair: BilingualRepairSession?
    static weak var pdf: PDFTranslationSession?
    static weak var pdfRuntime: PDFRuntimePreparationSession?
    static var credentialTransactionsReadyForQuit: Bool {
        providers?.credentialTransactionsReadyForQuit != false
            && processing?.credentialTransactionsReadyForQuit != false
    }
    var openMainWindow: (() -> Void)?
    private var isConfirmingQuit = false
    private var isFinishingQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        // NSWorkspace delivers this on the application's main run loop. Save
        // synchronously before returning instead of deferring until wake.
        Self.session?.systemWillSleep()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isConfirmingQuit, !isFinishingQuit else { return .terminateCancel }
        guard saveMaterialsBeforeQuit(allowUnfinishedBilingual: true) else { return .terminateCancel }
        guard let session = Self.session else { return beginFinishingQuit(sender) }
        if session.requestQuit() { return beginFinishingQuit(sender) }
        isConfirmingQuit = true
        sender.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text("停止录音并退出？", "Stop recording and quit?")
        alert.informativeText = text("退出前会停止采集并保存本次录音。取消后会保持当前录音状态。", "Capture will stop and your recording will be saved before quitting. Cancel to keep the current recording state.")
        alert.addButton(withTitle: text("停止并退出", "Stop and quit"))
        alert.addButton(withTitle: text("继续使用", "Keep open"))
        let response = alert.runModal()
        isConfirmingQuit = false
        guard response == .alertFirstButtonReturn else {
            session.cancelQuit()
            resumeBackgroundAfterCancelledQuit()
            return .terminateCancel
        }
        isFinishingQuit = true
        Self.backgroundGate?.suspendDispatch()
        Task { @MainActor in
            let canQuit = await session.confirmQuit()
            if canQuit { await Self.bilingualLive?.stop(); Self.bilingual?.finish() }
            // Keep cloud work alive if capture could not stop/save, or if the
            // user cancelled above. Only the committed exit interrupts it.
            let canFinish = canQuit && saveMaterialsBeforeQuit() && finishBackgroundWorkBeforeQuit()
            if canFinish { await Self.pdf?.awaitConfirmedShutdown(); await Self.pdfRuntime?.awaitShutdown(); await Self.repair?.awaitShutdown(); await Self.bilingualRepair?.awaitShutdown() }
            else { resumeBackgroundAfterCancelledQuit() }
            let durable = canFinish && Self.credentialTransactionsReadyForQuit
                && Self.providers?.prepareToQuit() != false
                && Self.repair?.prepareToQuit() != false && Self.bilingualRepair?.prepareToQuit() != false
            if !durable {
                resumeBackgroundAfterCancelledQuit()
                if canFinish { _ = saveMaterialsBeforeQuit() }
            }
            isFinishingQuit = false
            sender.reply(toApplicationShouldTerminate: durable)
            if !canQuit {
                let failure = NSAlert()
                failure.messageText = text("录音尚未保存，未退出", "Recording not saved — app kept open")
                failure.informativeText = session.lastError ?? text("请打开工作台重试保存。", "Open the workbench and retry saving.")
                failure.addButton(withTitle: text("好", "OK"))
                failure.runModal()
            }
        }
        return .terminateLater
    }

    private func beginFinishingQuit(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isFinishingQuit = true
        Self.backgroundGate?.suspendDispatch()
        Task { @MainActor in
            await Self.bilingualLive?.stop()
            Self.bilingual?.finish()
            let canFinish = saveMaterialsBeforeQuit() && finishBackgroundWorkBeforeQuit()
            if canFinish { await Self.pdf?.awaitConfirmedShutdown(); await Self.pdfRuntime?.awaitShutdown(); await Self.repair?.awaitShutdown(); await Self.bilingualRepair?.awaitShutdown() }
            else { resumeBackgroundAfterCancelledQuit() }
            let durable = canFinish && Self.credentialTransactionsReadyForQuit
                && Self.providers?.prepareToQuit() != false
                && Self.repair?.prepareToQuit() != false && Self.bilingualRepair?.prepareToQuit() != false
            if !durable {
                resumeBackgroundAfterCancelledQuit()
                if canFinish { _ = saveMaterialsBeforeQuit() }
            }
            isFinishingQuit = false
            sender.reply(toApplicationShouldTerminate: durable)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Closing a SwiftUI Window releases its NSWindow. Ask the scene to
        // recreate it instead of looking for a window that no longer exists.
        openMainWindow?()
        sender.activate(ignoringOtherApps: true)
        return true
    }

    private func saveMaterialsBeforeQuit(allowUnfinishedBilingual: Bool = false) -> Bool {
        guard Self.credentialTransactionsReadyForQuit, Self.providers?.prepareToQuit() != false else {
            openMainWindow?()
            let alert = NSAlert()
            if (Self.providers?.needsCredentialRecovery == true && Self.providers?.isUpdatingCredentials == false)
                || (Self.processing?.needsCredentialRecovery == true && Self.processing?.isUpdatingCredentials == false) {
                alert.messageText = text("凭据尚未恢复，未退出", "Credentials not restored — app kept open")
                alert.informativeText = text("请在设置中重试恢复原凭据，成功后再退出。退出会中断尚未完成的恢复。", "Retry restoring the original credentials in Settings, then quit after recovery succeeds. Quitting now would interrupt the unfinished recovery.")
            } else {
                alert.messageText = text("凭据操作尚未完成，未退出", "Credential operation unfinished — app kept open")
                alert.informativeText = text("正在保存或恢复凭据，请等待完成后再次退出。取消操作仍需等待已开始的系统写入和原凭据恢复完成。", "Credentials are being saved or restored. Wait for completion, then quit again. A cancelled operation must still finish any system write already started and restore the original credentials.")
            }
            alert.addButton(withTitle: text("继续使用", "Keep open"))
            alert.runModal()
            resumeBackgroundAfterCancelledQuit()
            return false
        }
        if Self.bilingualLive?.isActive == false { Self.bilingualLive?.retrySave() }
        let bilingualSaved = (allowUnfinishedBilingual
            ? Self.bilingual?.prepareEditsForQuit() != false : Self.bilingual?.prepareToQuit() != false)
            && (Self.bilingualLive?.isActive == true || Self.bilingualLive?.checkpointNeedsSaveRetry != true)
        let audioSaved = Self.processing?.prepareToQuit() != false
        let textSaved = Self.translation?.prepareToQuit() != false
        let resourcesSaved = Self.resources?.prepareToQuit() != false
        let pdfSaved = Self.pdf?.prepareToQuit() != false
        let repairSaved = Self.repair?.prepareToQuit() != false
        let bilingualRepairSaved = Self.bilingualRepair?.prepareToQuit() != false
        guard !audioSaved || !textSaved || !resourcesSaved || !bilingualSaved || !pdfSaved || !repairSaved || !bilingualRepairSaved else { return true }
        openMainWindow?()
        let alert = NSAlert()
        alert.messageText = text("资料尚未保存，未退出", "Material not saved — app kept open")
        alert.informativeText = text("已尝试本地保存。请检查磁盘空间与权限后重试，或先复制、导出当前草稿。没有重新提交云端处理。", "Local saving was attempted. Check disk space and permissions, then retry, or copy/export your draft first. Cloud processing was not resubmitted.")
        alert.addButton(withTitle: text("继续使用", "Keep open"))
        alert.runModal()
        resumeBackgroundAfterCancelledQuit()
        return false
    }

    private func resumeBackgroundAfterCancelledQuit() {
        Self.processing?.continueAfterCancelledQuit()
        Self.repair?.continueAfterCancelledQuit()
        Self.bilingualRepair?.continueAfterCancelledQuit()
        Self.backgroundGate?.resumeDispatch()
    }

    private func finishBackgroundWorkBeforeQuit() -> Bool {
        Self.backgroundGate?.suspendDispatch()
        let textReady = Self.translation?.prepareForConfirmedQuit() != false
        let audioReady = textReady && Self.processing?.prepareForConfirmedQuit() != false
        let pdfReady = audioReady && Self.pdf?.prepareForConfirmedQuit() != false
        guard !textReady || !audioReady || !pdfReady else { return true }
        openMainWindow?()
        let alert = NSAlert()
        alert.messageText = text("任务状态尚未保存，未退出", "Task state not saved — app kept open")
        alert.informativeText = text("请检查磁盘空间与权限，在文本或后台任务页重试本地保存后再退出。", "Check disk space and permissions, then retry local saving in Text or Tasks before quitting.")
        alert.addButton(withTitle: text("继续使用", "Keep open"))
        alert.runModal()
        return false
    }

    private func text(_ zh: String, _ en: String) -> String {
        AppLanguage.current.text(zh, en)
    }
}
