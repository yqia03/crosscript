import SwiftUI
import UniformTypeIdentifiers
import WorkbenchCore

// Select the property wrapper explicitly; newer SDKs also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct WorkbenchView: View {
    @ObservedObject var session: RecordingSession
    let playback: PlaybackController
    @ViewState<String?> private var playbackError = nil
    @ObservedObject var processing: PostRecordingSession
    @ObservedObject var providers: ProviderConfigurationSession
    @ObservedObject var translation: TextTranslationSession
    let pdf: PDFTranslationSession?
    let pdfRuntime: PDFRuntimePreparationSession?
    let legacyRecovery: LegacyTranscriptionRecoveryController?
    let repair: TranscriptRepairSession?
    let resources: TranslationResourceLibrary?
    let bilingual: BilingualSessionState?
    let bilingualStore: BilingualResultStore?
    let bilingualRepair: BilingualRepairSession?
    let geminiSettings: GeminiLiveSettings?
    let bilingualLive: LiveBilingualSession?
    let bilingualRecovery: BilingualDraftRecoveryController?
    let openCaptions: () -> Void
    @ViewState<Bool> private var showsImport = false
    @AppStorage("interfaceLanguage") private var languageChoice = AppLanguage.system.rawValue
    @ViewState<WorkbenchPage> private var page = .text
    @StateObject private var pdfDraft = PDFSubmissionDraft()
    @ViewState<Bool> private var showsRename = false
    @ViewState<Bool> private var showsBilingualHistory = false
    @ViewState<Bool> private var showsRecordingHistory = false
    @ViewState<UUID?> private var renameID = nil
    @ViewState<String> private var editedName = ""
    @ViewState<String?> private var renameError = nil
    @FocusState private var nameFieldFocused: Bool
    private let ink = Color(red: 0.15, green: 0.22, blue: 0.28)
    private let muted = Color(red: 0.36, green: 0.44, blue: 0.49)
    private let accent = Color(red: 0.16, green: 0.47, blue: 0.53)
    private var language: WorkbenchLanguage { WorkbenchLanguage(choice: AppLanguage(preference: languageChoice)) }
    private func t(_ zh: String, _ en: String) -> String { language.text(zh, en) }

    init(session: RecordingSession, playback: PlaybackController, processing: PostRecordingSession,
         providers: ProviderConfigurationSession, translation: TextTranslationSession,
         resources: TranslationResourceLibrary? = nil, pdf: PDFTranslationSession? = nil, pdfRuntime: PDFRuntimePreparationSession? = nil, legacyRecovery: LegacyTranscriptionRecoveryController? = nil, repair: TranscriptRepairSession? = nil,
         bilingual: BilingualSessionState? = nil, bilingualStore: BilingualResultStore? = nil, bilingualRepair: BilingualRepairSession? = nil,
         geminiSettings: GeminiLiveSettings? = nil,
         bilingualLive: LiveBilingualSession? = nil, bilingualRecovery: BilingualDraftRecoveryController? = nil,
         openCaptions: @escaping () -> Void = {}, initialPage: WorkbenchPage = .text) {
        self.session = session
        self.playback = playback
        self.processing = processing
        self.providers = providers
        self.translation = translation
        self.pdf = pdf
        self.pdfRuntime = pdfRuntime
        self.legacyRecovery = legacyRecovery
        self.repair = repair
        self.resources = resources
        self.bilingual = bilingual
        self.bilingualStore = bilingualStore
        self.bilingualRepair = bilingualRepair
        self.geminiSettings = geminiSettings
        self.bilingualLive = bilingualLive
        self.bilingualRecovery = bilingualRecovery
        self.openCaptions = openCaptions
        _page = ViewState(initialValue: initialPage)
    }

    private var recordingActions: RecordingActions { .init(recordings: session, bilingual: bilingualLive) }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900
            HStack(spacing: compact ? 10 : 22) {
                navigation(compact: compact)
                VStack(spacing: 14) {
                    if page == .live {
                        VStack(alignment: .leading, spacing: 12) {
                            workspaceNotices
                            livePage
                        }
                        .padding(.vertical, 8).padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                if page != .pdf && page != .text { pageHeader }
                                workspaceNotices
                                pageContent(compact: compact, height: geometry.size.height)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 2)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    if session.hasActiveRecording && (page != .recording || session.selectedID != session.activeID)
                        && !(page == .live && bilingualLive?.isActive == true) { activeStrip(compact: compact) }
                    if page != .live, let bilingualLive { BilingualActivityStrip(live: bilingualLive) { page = .live } }
                    if let id = processing.runningID {
                        Button { openAudioMaterial(id, showHistory: true) } label: {
                            Label(t("录后转写中 · ", "Transcribing · ") + (session.recordings.first { $0.id == id }?.name ?? ""), systemImage: "cloud")
                                .font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless).padding(12).glassCard()
                    }
                    if page != .text, translation.isRunning || translation.hasPendingSave {
                        Button {
                            page = .text
                        } label: {
                            Label(translation.isRunning
                                  ? t("文本翻译进行中", "Text translation in progress")
                                  : t("文本草稿待保存 · 返回处理", "Text draft needs saving · Open draft"),
                                  systemImage: "character.bubble")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless).padding(12).glassCard()
                    }
                    if page != .pdf, let pdf { PDFActivityStrip(session: pdf) { _ in page = .pdf } }
                    if page != .live { footer }
                }
                .padding(.trailing, compact ? 20 : 32).padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background).foregroundStyle(ink).tint(accent)
            .environment(\.locale, language.locale)
            .fileImporter(isPresented: $showsImport, allowedContentTypes: AudioImportFormats.extensions.sorted().compactMap { UTType(filenameExtension: $0) }) { result in
                if case .success(let url) = result {
                    Task { await session.importAudio(from: url, using: NativeAudioImporter()); page = .recording }
                }
            }
            .sheet(isPresented: $showsRename) { renameSheet }
            .sheet(isPresented: $showsBilingualHistory) { bilingualHistorySheet }
            .sheet(isPresented: $showsRecordingHistory) {
                RecordingHistoryView(session: session, processing: processing) { id in
                    openAudioMaterial(id)
                    showsRecordingHistory = false
                }
            }
            .sheet(isPresented: Binding(get: { processing.pendingDeletion != nil }, set: { if !$0 { processing.cancelDeletion() } })) {
                if let confirmation = processing.pendingDeletion {
                    MaterialDeletionConfirmationView(processing: processing, confirmation: confirmation, beforeDelete: { playback.stop() })
                }
            }
            .onReceive(playback.$lastError.removeDuplicates()) { playbackError = $0 }
            .onChange(of: page, initial: true) { _, destination in
                if destination == .recording { session.activateWorkflow(.transcription) }
                if destination == .live { session.activateWorkflow(.liveTranslation); openSelectedBilingualResult() }
            }
            .onChange(of: session.selectedID) { _, _ in
                playback.stop(); playback.dismissError()
                if page == .live { openSelectedBilingualResult() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCurrentRecording)) { _ in
                page = session.selectedRecording?.workflow == .liveTranslation || bilingualLive?.isActive == true ? .live : .recording
            }
        }
        .frame(minWidth: 680, minHeight: 640)
        .preferredColorScheme(.light)
    }

    @ViewBuilder private var workspaceNotices: some View {
        if let legacyRecovery { LegacyTranscriptionRecoveryBanner(recovery: legacyRecovery) }
        if let bilingualRecovery { BilingualDraftRecoveryBanner(recovery: bilingualRecovery) }
        if let error = session.lastError ?? playbackError { errorBanner(error) }
        if let error = processing.error { processingError(error) }
        if let error = processing.deletionError, processing.pendingDeletion == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(error.description(language.choice)).font(.callout)
                Button(t("关闭提示", "Dismiss")) { processing.dismissDeletionError() }.buttonStyle(.borderless)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard()
        }
    }

    @ViewBuilder private func pageContent(compact: Bool, height: CGFloat) -> some View {
        switch page {
        case .recording: recordingPage(compact: compact)
        case .history: historyPage
        case .settings: settingsPage
        case .tasks: tasksPage
        case .text: TextTranslationView(session: translation, providers: providers, resources: resources,
            openSettings: { page = .settings }, workspaceHeight: max(500, height - 165))
        case .pdf:
            if let pdf, let pdfRuntime { PreparedPDFSection(session: pdf, runtime: pdfRuntime, providers: providers, resources: resources, openSettings: { page = .settings }, draft: pdfDraft) }
            else if let pdf { PDFTranslationView(session: pdf, providers: providers, openSettings: { page = .settings }, resources: resources, draft: pdfDraft) }
            else { pendingPage }
        case .live: EmptyView()
        }
    }

    @ViewBuilder private var livePage: some View {
        if let bilingual {
            BilingualTranscriptView(state: bilingual, recordings: session,
                configuration: geminiSettings?.configuration ?? AudioServiceConfiguration(provider: .gemini),
                openSettings: { page = .settings }, openCaptions: openCaptions,
                live: bilingualLive, beforeStart: { playback.stop() }, canStartRecording: recordingActions.canStart,
                fillsAvailableHeight: true, renameRecording: beginRename)
            if let recording = session.selectedRecording, recording.workflow == .liveTranslation, bilingualStore != nil {
                Button { showsBilingualHistory = true } label: {
                    Label(t("历史结果、编辑与回听", "Results, editing and playback"), systemImage: "clock.arrow.circlepath")
                }.buttonStyle(.borderless).disabled(bilingualLive?.isActive == true)
            }
        } else { pendingPage }
    }

    private func openSelectedBilingualResult() {
        guard let bilingual else { return }
        guard bilingual.canReplaceResult, bilingualLive?.isActive != true else {
            if let owner = bilingual.result?.recordingID, session.selectedID != owner { session.select(owner) }
            return
        }
        guard let recording = session.selectedRecording, recording.workflow == .liveTranslation,
              let bilingualStore else { bilingual.reopen(nil); return }
        let history = bilingual.history(recordingID: recording.id, store: bilingualStore)
        history.reload()
        bilingual.reopen(history.selected)
    }

    func openAudioMaterial(_ id: UUID, showHistory: Bool = false) {
        guard let recording = session.recordings.first(where: { $0.id == id }) else { return }
        if recording.workflow == .liveTranslation, let bilingual, !bilingual.canReplaceResult,
           let owner = bilingual.result?.recordingID, owner != id {
            session.select(owner); page = .live
            return
        }
        session.select(id)
        page = recording.workflow == .liveTranslation ? .live : .recording
        if page == .live {
            openSelectedBilingualResult()
            showsBilingualHistory = showHistory && bilingualLive?.isActive != true
        }
    }

    @ViewBuilder private var bilingualHistorySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("同声传译历史", "Live translation history")).font(.title2)
                Spacer()
                Button(t("完成", "Done")) { showsBilingualHistory = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let recording = session.selectedRecording, let bilingual, let bilingualStore {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(recording.name).font(.headline)
                        RecordingPlaybackControls(playback: playback, url: session.audioURL(for: recording.id),
                            duration: recording.duration, language: language)
                        BilingualHistoryView(recordingID: recording.id, store: bilingualStore, state: bilingual,
                            openLive: { showsBilingualHistory = false }, repair: bilingualRepair,
                            repairConfiguration: GeminiFileRepairConfiguration.configuration, recordingName: recording.name,
                            deletionBlockReason: { id in processing.deletionBlockReason(for: .material(recordingID: id)) })
                            .id(recording.id)
                        if let legacy = processing.materials[recording.id], !legacy.results.isEmpty {
                            DisclosureGroup(t("旧版附带的转写结果", "Transcripts retained from earlier versions")) {
                                ForEach(legacy.results) { result in
                                    TranscriptEditorView(processing: processing, recording: recording, result: result, playFrom: { time in
                                        do { try playback.play(at: time, from: session.audioURL(for: recording.id)) }
                                        catch { /* PlaybackController publishes the error. */ }
                                    }).id(result.id)
                                }
                            }
                        }
                    }.padding(2)
                }
            }
        }.padding(24).frame(minWidth: 560, idealWidth: 760, minHeight: 480, idealHeight: 640)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.93, green: 0.96, blue: 0.97)
            LinearGradient(colors: [Color(red: 0.88, green: 0.91, blue: 0.97), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.86, green: 0.94, blue: 0.90), .clear], center: .topTrailing, startRadius: 10, endRadius: 740)
        }.ignoresSafeArea()
    }

    private func navigation(compact: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle").font(.system(size: 26, weight: .light)).foregroundStyle(accent).padding(.top, 28).accessibilityHidden(true)
            Spacer(minLength: 12)
            VStack(spacing: 5) {
                ForEach(WorkbenchPage.allCases) { destination in
                    if destination == .tasks { Divider().padding(.horizontal, 18).padding(.vertical, 3) }
                    Button {
                        page = destination
                        if destination == .history { session.refresh() }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: destination.symbol).font(.system(size: 19))
                            Text(destination.title(language)).font(.system(size: language.isChinese ? 10 : 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(width: compact ? 59 : 67, height: 54)
                        .foregroundStyle(page == destination ? .white : muted)
                        .background {
                            if page == destination {
                                RoundedRectangle(cornerRadius: 17).fill(LinearGradient(colors: [accent.opacity(0.88), accent], startPoint: .topLeading, endPoint: .bottomTrailing)).shadow(color: accent.opacity(0.2), radius: 7, y: 4)
                            }
                        }.contentShape(RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain).help(destination.title(language) + " · ⌘" + String(destination.shortcut))
                    .keyboardShortcut(KeyEquivalent(destination.shortcut), modifiers: .command)
                    .accessibilityLabel(destination.title(language))
                    .accessibilityAddTraits(page == destination ? .isSelected : [])
                }
            }
            .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27))
            .overlay(RoundedRectangle(cornerRadius: 27).stroke(.white.opacity(0.9), lineWidth: 1))
            .shadow(color: ink.opacity(0.06), radius: 20, y: 10)
            Spacer(minLength: 12)
            Text(t("本地工作台", "LOCAL WORKSPACE")).font(.system(size: language.isChinese ? 10 : 7, weight: .medium)).foregroundStyle(muted).padding(.bottom, 20)
        }
        .frame(width: compact ? 86 : 104).frame(maxHeight: .infinity).padding(.leading, compact ? 5 : 10)
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                if page == .recording, let recording = session.selectedRecording {
                    Button { beginRename(recording) } label: {
                        HStack(spacing: 10) {
                            Text(recording.name).lineLimit(2).multilineTextAlignment(.leading)
                            Image(systemName: "pencil").font(.system(size: 15)).foregroundStyle(muted)
                        }.font(.system(size: 27, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.plain).help(t("修改录音名称", "Rename recording"))
                    .accessibilityLabel(t("修改录音名称：", "Rename recording: ") + recording.name)
                    Text(language.date(recording.startedAt)).font(.system(size: 12)).foregroundStyle(muted)
                } else {
                    Text(page.title(language)).font(.system(size: 28, weight: .semibold, design: .rounded))
                    if page != .text { Text(page.subtitle(language)).font(.system(size: 13)).foregroundStyle(muted) }
                }
            }
            Spacer(minLength: 0)
            if page == .recording {
                Button { session.refresh(); showsRecordingHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }.buttonStyle(WorkbenchCompactButtonStyle(iconOnly: true)).fixedSize()
                    .accessibilityLabel(t("录音历史记录", "Recording history")).help(t("历史记录", "History"))
                Button {
                    playback.stop()
                    session.newProject()
                } label: {
                    Label(t("新建项目", "New project"), systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 11)
                        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).fixedSize().disabled(!recordingActions.canStart)

            }
        }.padding(.top, 6)
    }

    private func recordingPage(compact: Bool) -> some View {
        VStack(spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { localStatus.frame(minWidth: 235); cloudStatus.frame(minWidth: 235) }
                VStack(spacing: 12) { localStatus; cloudStatus }
            }
            if let recording = session.selectedRecording, recording.workflow == .transcription {
                if compact {
                    VStack(spacing: 16) { recordingWorkspace(recording); transcriptPanel(recording) }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        recordingWorkspace(recording).frame(maxWidth: .infinity)
                        transcriptPanel(recording).frame(maxWidth: .infinity)
                    }
                }
            }
            else { emptyRecording }
        }
    }

    private var localStatus: some View {
        let selected = session.selectedRecording
        let active = selected?.id == session.activeID && session.activeID != nil
        return statusCard(title: t("本地录音", "LOCAL RECORDING"),
            value: active ? session.activityTitle(using: language.choice) : (selected.map { statusTitle($0) } ?? t("准备就绪", "Ready to record")),
            detail: active ? (selected?.source.title(using: language) ?? "") + t(" · 本地保存", " · Saved locally") : t("音频与云端处理独立", "Independent of cloud processing"),
            symbol: active ? "mic.fill" : "checkmark.shield", color: active ? Color(red: 0.75, green: 0.31, blue: 0.38) : accent)
    }
    private var cloudStatus: some View {
        let title = session.selectedID.flatMap { processing.statusTitle(for: $0, language: language.choice) }
            ?? t("尚未开始转写", "Not transcribed")
        return statusCard(title: t("云端处理", "CLOUD PROCESSING"), value: title,
            detail: t("音频不会自动上传", "Audio is not uploaded automatically"), symbol: "cloud", color: Color(red: 0.33, green: 0.48, blue: 0.62))
    }
    private func statusCard(title: String, value: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color).frame(width: 44, height: 44).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                Text(value).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }
    private var emptyRecording: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(t("录音", "Recording"), systemImage: "waveform").font(.system(size: 14, weight: .semibold)).padding(20)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 24) {
                AudioSourceSelection(session: session, language: language)
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(accent)
                    Text(t("项目已就绪", "Your project is ready")).font(.system(size: 22, weight: .medium, design: .rounded))
                    Text(t("开始一段录音，或导入已有音频。", "Start a recording or import an audio file."))
                        .font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center)
                    Text(t("点击开始时才请求音频权限。", "Audio permission is requested only when you start."))
                        .font(.system(size: 11)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 22)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { startButton; importButton }
                    VStack(spacing: 12) { startButton; importButton }
                }.frame(maxWidth: .infinity, alignment: .center)
            }.padding(24)
            Divider().opacity(0.5)
            Label(t("音频保存在这台 Mac 上", "Audio stays on this Mac"), systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(muted).padding(18)
        }.frame(maxWidth: 700, alignment: .leading).glassCard().frame(maxWidth: .infinity)
    }

    private func recordingWorkspace(_ recording: Recording) -> some View {
        let active = recording.id == session.activeID
        return VStack(spacing: 0) {
            HStack {
                Label(t("录音", "Recording"), systemImage: "waveform").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(statusTitle(recording)).font(.system(size: 11)).foregroundStyle(muted)
            }.padding(20)
            Divider().opacity(0.5)
            VStack(spacing: 22) {
                if active { AudioSourceSelection(session: session, language: language) }
                else {
                    Label(recording.sourceTitle(using: language), systemImage: recording.sourceSymbol)
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                Image(systemName: active ? "mic.fill" : "waveform.circle").font(.system(size: 43, weight: .ultraLight)).foregroundStyle(accent)
                RecordingClockView(telemetry: session.telemetry, fixedDuration: active ? nil : recording.duration)
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .accessibilityLabel(t("录音时长", "Recording duration"))
                if active {
                    inputMeter.frame(maxWidth: 290)
                    Text(session.needsSaveRetry ? t("音频已停止采集，请重试保存。", "Capture has stopped. Please retry saving.") : session.isPaused ? t("暂停期间不采集新音频。继续后仍为本次录音。", "No new audio is captured while paused. Resume to continue this recording.") : t("正在采集：", "Capturing: ") + recording.source.title(using: language))
                        .font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center)
                } else {
                    RecordingPlaybackControls(playback: playback, url: session.audioURL(for: recording.id), duration: recording.duration, language: language)
                    if recording.status == .interrupted {
                        Label(recording.interruptionDescription(using: language.choice), systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if active { activeActions }
                else {
                    VStack(spacing: 8) {
                        importButton
                        Button(role: .destructive) {
                            processing.requestDeletion(.material(recordingID: recording.id))
                        } label: { Label(t("删除整份资料…", "Delete entire material…"), systemImage: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(processing.deletionBlockReason(for: .material(recordingID: recording.id)) != nil)
                        if let reason = processing.deletionBlockReason(for: .material(recordingID: recording.id)) {
                            Text(reason.description(language.choice)).font(.caption).foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(t("导入会创建新项目，保留当前资料。", "Import creates a new project and keeps this material."))
                            .font(.system(size: 11)).foregroundStyle(muted).multilineTextAlignment(.center)
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 28).frame(maxWidth: .infinity)
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                Text(t("原始音频", "Original audio"))
                Spacer()
                Text(active ? (session.needsSaveRetry ? t("已停止，等待保存", "Stopped · Awaiting save") : session.isPaused ? t("暂停，已有音频保留", "Paused · Audio retained") : t("音频正在本地保存", "Audio is being saved locally")) : t("已保留原始音频", "Original audio retained"))
            }.font(.system(size: 11)).foregroundStyle(muted).padding(18)
        }.glassCard()
    }
    private var importButton: some View {
        Button { showsImport = true } label: {
            Label(session.isImporting ? t("正在导入…", "Importing…") : t("导入音频", "Import audio"), systemImage: "square.and.arrow.down")
                .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 11)
                .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(!recordingActions.canStart)
    }

    private func transcriptPanel(_ recording: Recording) -> some View {
        PostRecordingView(processing: processing, recording: recording,
                          canProcess: recording.id != session.activeID && !session.isBusy,
                          repair: repair,
                          openSettings: { page = .settings }, playFrom: { time in
            do { try playback.play(at: time, from: session.audioURL(for: recording.id)) }
            catch { /* PlaybackController publishes this error. */ }
        }).id(recording.id)
    }

    private func processingError(_ error: AudioProcessingError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(t("音频服务设置", "Audio service settings")) { page = .settings }
                Button(t("关闭提示", "Dismiss")) { processing.dismissError() }
            }.buttonStyle(.borderless)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private var tasksPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            AudioQueueView(processing: processing) { id in
                openAudioMaterial(id, showHistory: true)
            }
            if let pdf { PDFQueueSection(session: pdf) { _ in page = .pdf } }
            if let repair {
                TranscriptRepairQueueSection(repair: repair, recordings: session, configuration: processing.configuration) { id in
                    openAudioMaterial(id, showHistory: true)
                }
            }
            if let bilingualRepair {
                BilingualRepairQueueSection(repair: bilingualRepair, recordings: session) { id in
                    openAudioMaterial(id, showHistory: true)
                }
            }
        }
    }

    private var inputMeter: some View {
        RecordingInputMeter(telemetry: session.telemetry, language: language)
    }
    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(t("\(session.recordings(in: .transcription).count) 份转写 · \(session.recordings(in: .liveTranslation).count) 份同传 · \(translation.history.count) 条文本翻译",
                       "\(session.recordings(in: .transcription).count) transcriptions · \(session.recordings(in: .liveTranslation).count) live translations · \(translation.history.count) text translations"))
                    .font(.system(size: 12)).foregroundStyle(muted)
                Spacer()
                Button { session.refresh() } label: { Label(t("刷新", "Refresh"), systemImage: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            if let pdf { PDFHistorySection(session: pdf) { _ in page = .pdf } }
            if session.recordings.isEmpty && translation.history.isEmpty && pdf == nil {
                VStack(spacing: 15) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 40, weight: .light)).foregroundStyle(accent)
                    Text(t("这里会留下你的资料", "Your materials will be here")).font(.system(size: 21, weight: .medium))
                    Text(t("录音与文本会分别保留，可在这里重新打开继续工作。", "Recordings and text are kept separately. Reopen either here to continue working.")).font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center)
                    Button { page = .recording } label: { Label(t("前往录音", "Go to recording"), systemImage: "mic") }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding(45).glassCard()
            } else {
                TextTranslationHistoryList(session: translation) { page = .text }
                RecordingHistoryList(session: session, processing: processing, workflow: nil,
                    open: { openAudioMaterial($0) }, rename: beginRename,
                    delete: { processing.requestDeletion(.material(recordingID: $0)) })
            }
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                Label(t("显示", "Display"), systemImage: "textformat").font(.system(size: 16, weight: .semibold))
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("界面语言", "Interface language")).font(.system(size: 14, weight: .medium))
                        Text(t("仅调整应用界面的语言。", "Changes the language of the app interface.")).font(.system(size: 12)).foregroundStyle(muted)
                    }
                    Spacer(minLength: 16)
                    Picker(t("界面语言", "Interface language"), selection: $languageChoice) {
                        ForEach(AppLanguage.allCases) { choice in Text(choice.title(using: language)).tag(choice.rawValue) }
                    }.labelsHidden().frame(width: 145)
                }
            }.padding(24).glassCard()
            AudioConfigurationView(processing: processing)
            if let geminiSettings { GeminiLiveSettingsView(settings: geminiSettings) }
            ProviderConfigurationView(session: providers)
            if let resources { TranslationResourceManagementView(library: resources) }
        }
    }
    private var pendingPage: some View {
        VStack(spacing: 18) {
            Image(systemName: page.symbol).font(.system(size: 40, weight: .light)).foregroundStyle(accent).frame(width: 90, height: 90).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 25))
            Text(page == .tasks ? t("暂无后台处理任务", "No background processing tasks") : t("这个功能正在准备中", "This feature is being prepared")).font(.system(size: 23, weight: .medium))
            Text(page.pendingDescription(language)).font(.system(size: 14)).foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(6).frame(maxWidth: 490)
            Button { page = .recording } label: { Label(t("返回录音", "Back to recording"), systemImage: "mic") }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 56).glassCard()
    }

    private func activeStrip(compact: Bool) -> some View {
        VStack(spacing: 12) {
          HStack(spacing: compact ? 12 : 22) {
            Button {
                if let id = session.activeID { session.select(id) }
                page = session.activeRecording?.workflow == .liveTranslation ? .live : .recording
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: session.needsSaveRetry ? "exclamationmark.circle" : session.isPaused ? "pause.fill" : "mic.fill").font(.system(size: 20)).foregroundStyle(Color(red: 0.75, green: 0.31, blue: 0.38))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.activityTitle(using: language.choice)).font(.system(size: 12, weight: .semibold))
                        Text((session.activeRecording?.source.title(using: language) ?? "") + " · " + (session.activeRecording?.name ?? "")).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                    }
                }
            }.buttonStyle(.plain).help(t("返回当前录音", "Open current recording"))
            RecordingClockView(telemetry: session.telemetry).font(.system(size: compact ? 16 : 19, weight: .medium, design: .monospaced)).fixedSize()
            Spacer(minLength: 0)
          }
        }.padding(17).glassCard()
    }

    private var activeActions: some View {
        HStack(spacing: 10) {
            if !session.needsSaveRetry {
                Button {
                    Task { await recordingActions.togglePause() }
                } label: {
                    Label(recordingActions.isFinishingPause ? t("暂停收尾中…", "Finishing pause…") : session.isPaused ? t("继续录音", "Resume") : t("暂停录音", "Pause"), systemImage: session.isPaused ? "record.circle" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold)).padding(.vertical, 7)
                }.buttonStyle(.bordered).clipShape(RoundedRectangle(cornerRadius: 12)).disabled(!recordingActions.canTogglePause)
            }
            Button { Task { await recordingActions.stop() } } label: {
                Label(session.needsSaveRetry ? t("重试保存", "Retry save") : t("停止并保存", "Stop & save"), systemImage: session.needsSaveRetry ? "arrow.clockwise" : "stop.fill").font(.system(size: 12, weight: .semibold)).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 12)).disabled(session.isBusy).keyboardShortcut(".", modifiers: [.command])
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var startButton: some View {
        Button {
            playback.stop()
            Task { await session.start() }
        } label: {
            HStack(spacing: 7) {
                if session.isBusy { ProgressView().controlSize(.small) } else { Image(systemName: session.selectedSource.symbol) }
                Text(t("开始录音", "Start recording"))
            }.font(.system(size: 13, weight: .semibold)).padding(.vertical, 7)
        }.buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(!recordingActions.canStart).keyboardShortcut("r", modifiers: [.command, .shift])
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(accent.opacity(0.65)).frame(width: 5, height: 5)
            Text("Crosscript"); Spacer()
            Text(t("本地保存 · 手动云端处理", "Local storage · Manual cloud processing"))
        }.font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 5)
    }
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(red: 0.58, green: 0.39, blue: 0.16))
            VStack(alignment: .leading, spacing: 5) {
                Text(t("操作未完成", "Action could not be completed")).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(t("可修正问题后重试；已有录音不会因此被删除。", "Correct the problem and try again. Existing recordings are retained.")).font(.system(size: 11)).foregroundStyle(muted)
                Button { openAudioPrivacySettings(for: session.selectedSource) } label: {
                    Label(t("打开音频权限设置", "Open audio permission settings"), systemImage: "arrow.up.right.square")
                }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Spacer(minLength: 0)
            Button { session.dismissError(); playback.dismissError() } label: { Image(systemName: "xmark").padding(4) }
                .buttonStyle(.plain).accessibilityLabel(t("关闭错误提示", "Dismiss error"))
        }.padding(16).background(Color(red: 0.99, green: 0.96, blue: 0.88), in: RoundedRectangle(cornerRadius: 15))
    }
    private func beginRename(_ recording: Recording) {
        renameID = recording.id
        editedName = recording.name
        renameError = nil
        showsRename = true
    }
    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("修改录音名称", "Rename recording")).font(.system(size: 22, weight: .semibold))
            Text(t("名称会同步到历史资料。留空将使用录音开始时间。", "The name also updates in History. Leave it blank to use the recording start time.")).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(t("录音名称", "Recording name"), text: $editedName).textFieldStyle(.roundedBorder).font(.system(size: 16)).focused($nameFieldFocused).onSubmit(saveRename)
            if let renameError {
                Text(renameError).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(t("取消", "Cancel")) { showsRename = false }.keyboardShortcut(.cancelAction)
                Button(t("保存名称", "Save name"), action: saveRename).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(session.isBusy)
            }
        }.padding(28).frame(width: 430).onAppear { nameFieldFocused = true }
    }
    private func saveRename() {
        guard !session.isBusy, let id = renameID,
              let recording = session.recordings.first(where: { $0.id == id }) else { return }
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = trimmed.isEmpty ? recording.defaultName : trimmed
        session.dismissError()
        session.rename(id: id, name: editedName)
        if let error = session.lastError {
            renameError = error
        } else if session.recordings.first(where: { $0.id == id })?.name == expected {
            renameError = nil
            showsRename = false
        } else {
            renameError = t("名称未能保存，请重试。", "The name could not be saved. Please try again.")
        }
    }
    private func statusTitle(_ recording: Recording) -> String {
        if recording.id == session.activeID && session.needsSaveRetry {
            return t("已停止，待保存", "Stopped · Save pending")
        }
        return recording.statusTitle(using: language.choice)
    }
    private func clockString(_ seconds: TimeInterval) -> String {
        recordingClock(seconds)
    }
}

enum WorkbenchPage: String, CaseIterable, Identifiable {
    case text, recording, pdf, live, history, tasks, settings
    var id: String { rawValue }
    var shortcut: Character {
        switch self {
        case .live: return "4"
        case .recording: return "2"
        case .pdf: return "3"
        case .text: return "1"
        case .history: return "5"
        case .tasks: return "6"
        case .settings: return "7"
        }
    }
    var symbol: String {
        switch self {
        case .live: return "waveform"
        case .recording: return "mic"
        case .pdf: return "doc.text"
        case .text: return "character.bubble"
        case .history: return "clock.arrow.circlepath"
        case .tasks: return "square.3.layers.3d"
        case .settings: return "slider.horizontal.3"
        }
    }
    func title(_ l: WorkbenchLanguage) -> String {
        switch self {
        case .live: return l.text("同声传译", "Live translation")
        case .recording: return l.text("录音转写", "Recording")
        case .pdf: return l.text("PDF 翻译", "PDF translation")
        case .text: return l.text("文本翻译", "Text translation")
        case .history: return l.text("历史资料", "History")
        case .tasks: return l.text("后台任务", "Tasks")
        case .settings: return l.text("设置", "Settings")
        }
    }
    func subtitle(_ l: WorkbenchLanguage) -> String {
        switch self {
        case .live: return l.text("在原文与译文之间，跟上每一句话。", "Follow each sentence in both languages.")
        case .recording: return l.text("留住声音，随时回听。", "Keep the sound. Listen again anytime.")
        case .pdf: return l.text("为阅读保留原文与译文。", "Keep the original and translation together.")
        case .text: return l.text("对照阅读原文与译文，保存你的修改。", "Read the original and translation together. Keep your edits.")
        case .history: return l.text("你的录音与文本，保存在这里。", "Your recordings and text, kept here.")
        case .tasks: return l.text("查看资料处理的进度。", "Follow the progress of your processing tasks.")
        case .settings: return l.text("让工作台适合你的习惯。", "Make the workspace feel like yours.")
        }
    }
    func pendingDescription(_ l: WorkbenchLanguage) -> String {
        switch self {
        case .live: return l.text("同声传译尚未接入。现在可以先录制麦克风或系统声音，并从历史资料回听。", "Live translation is not connected yet. You can record microphone or system audio and listen again from History.")
        case .pdf: return l.text("PDF 翻译与阅读将在后续版本开放。\n当前页面不会上传或处理文件。", "PDF translation and reading will be available in a later version.\nThis page does not upload or process files.")
        case .text, .tasks: return ""
        default: return ""
        }
    }
}
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.9), lineWidth: 1))
            .shadow(color: Color(red: 0.16, green: 0.25, blue: 0.31).opacity(0.035), radius: 15, y: 6)
    }
}
extension View { func glassCard() -> some View { modifier(GlassCard()) } }
