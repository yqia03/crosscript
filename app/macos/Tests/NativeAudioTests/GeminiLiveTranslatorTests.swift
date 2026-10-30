import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@MainActor struct GeminiLiveTranslatorTests {
    @Test func pausingFlushesAllCapturedPCMWithAShortTailBeforeEndingInput() async throws {
        let connection = ControlledGeminiConnection()
        let translator = GeminiLiveTranslator { _ in connection }
        defer { translator.close() }
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-test-key")
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .configured)
        try await translator.append(LiveAudioChunk(pcm16: Data(repeating: 7, count: 4802), recordingStartFrame: 0))
        let began = ContinuousClock.now
        try await translator.pauseInput()
        #expect(began.duration(to: .now) < .seconds(1))
        let messages = try connection.sent.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let packets = try messages.compactMap { message -> Data? in
            guard let audio = (message?["realtimeInput"] as? [String: Any])?["audio"] as? [String: String] else { return nil }
            return try #require(Data(base64Encoded: #require(audio["data"])))
        }
        #expect(packets.reduce(0) { $0 + $1.count } == 3202 + 19_200)
        #expect(packets.suffix(6).allSatisfy { $0 == Data(repeating: 0, count: 3200) })
        #expect((messages.last??["realtimeInput"] as? [String: Bool]) == ["audioStreamEnd": true])
    }

    @Test func finishingAdvancesTheServiceAudioClockOnceWithoutMovingTheRecordingClock() async throws {
        let connection = ControlledGeminiConnection()
        let translator = GeminiLiveTranslator { _ in connection }
        defer { translator.close() }
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-test-key")
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .configured)
        try await translator.append(LiveAudioChunk(pcm16: Data(repeating: 7, count: 4802), recordingStartFrame: 0))
        try await translator.finishInput()
        let packets = try connection.sent.compactMap { data -> Data? in
            let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let audio = (message?["realtimeInput"] as? [String: Any])?["audio"] as? [String: String],
                  let encoded = audio["data"] else { return nil }
            return try #require(Data(base64Encoded: encoded))
        }
        #expect(packets.reduce(0) { $0 + $1.count } == ((2401 * 2 + 2) / 3) * 2 + 4 * 16_000 * 2)
        #expect(packets.suffix(40).count == 40)
        #expect(packets.suffix(40).allSatisfy { $0 == Data(repeating: 0, count: 3200) })
        let finishedCount = connection.sent.count
        try await translator.finishInput()
        #expect(connection.sent.count == finishedCount)
        // Protocol silence cannot become part of the original media clock.
        try await translator.append(LiveAudioChunk(pcm16: Data(repeating: 9, count: 4800), recordingStartFrame: 2401))
        #expect(!connection.isClosed)
        connection.deliver(Data(#"{"serverContent":{"inputTranscription":{"text":"Tail."}}}"#.utf8))
        guard case .text(.source, _, "Tail.", nil, nil, nil) = try await iterator.next() else {
            Issue.record("Late source tail was discarded"); return
        }
        connection.deliver(Data(#"{"serverContent":{"outputTranscription":{"text":"句尾。"}}}"#.utf8))
        guard case .text(.translation, _, "句尾。", nil, nil, nil) = try await iterator.next() else {
            Issue.record("Late translated tail was discarded"); return
        }
    }

    @Test(arguments: [24_000, 24_301])
    func capturedPCMIsResampledIntoBoundedPacketsAndEndDoesNotClaimCompletion(frameCount: Int) async throws {
        let connection = ControlledGeminiConnection()
        var requests: [URLRequest] = []
        let translator = GeminiLiveTranslator { request in requests.append(request); return connection }
        defer { translator.close() }
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-test-key")
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .configured)
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "x-goog-api-key") == "synthetic-test-key")
        #expect(requests.first?.url?.query == nil)
        let samples = (0..<frameCount).map { Int16((10_000 * sin(2 * Double.pi * 1_000 * Double($0) / 24_000)).rounded()).littleEndian }
        let pcm = samples.withUnsafeBytes { Data($0) }
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + 703)
            try await translator.append(LiveAudioChunk(pcm16: pcm.subdata(in: start * 2..<end * 2), recordingStartFrame: Int64(start)))
            start = end
        }
        try await translator.finishInput()
        let messages = try connection.sent.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let packets = try messages.compactMap { message -> Data? in
            guard let audio = (message?["realtimeInput"] as? [String: Any])?["audio"] as? [String: String] else { return nil }
            #expect(audio["mimeType"] == "audio/pcm;rate=16000")
            let encoded = try #require(audio["data"])
            guard let decoded = Data(base64Encoded: encoded) else { Issue.record("Invalid outbound PCM"); return nil }
            return decoded
        }
        #expect(!packets.isEmpty)
        #expect(packets.allSatisfy { !$0.isEmpty && $0.count <= 3200 && $0.count.isMultiple(of: 2) })
        #expect(packets.suffix(40).allSatisfy { $0 == Data(repeating: 0, count: 3200) })
        let mediaPackets = Array(packets.dropLast(40))
        #expect(mediaPackets.dropLast().allSatisfy { $0.count == 3200 })
        let output = mediaPackets.reduce(into: Data()) { $0.append($1) }
        let values = stride(from: 0, to: output.count, by: 2).map { index in
            Double(Int16(bitPattern: UInt16(output[index]) | UInt16(output[index + 1]) << 8))
        }
        #expect(values.count == (frameCount * 2 + 2) / 3)
        if frameCount == 24_301 { #expect(mediaPackets.last?.count == 402) }
        let middle = Array(values.dropFirst(100).dropLast(100))
        let rms = sqrt(middle.reduce(0) { $0 + $1 * $1 } / Double(middle.count))
        #expect(rms > 6500 && rms < 7600)
        let crossings = zip(middle, middle.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        let frequency = Double(crossings) * 16_000 / Double(middle.count)
        #expect(frequency > 980 && frequency < 1020)
        #expect((messages.last??["realtimeInput"] as? [String: Bool]) == ["audioStreamEnd": true])
        connection.deliver(Data(#"{"serverContent":{"turnComplete":true,"interactionStatus":"IDLE"}}"#.utf8))
        #expect(try await iterator.next() == .turnComplete)
        #expect(try await iterator.next() == .interactionStatus(.idle))
        translator.close()
        #expect(try await iterator.next() == nil)
    }

    @Test func readerFailuresKeepTypedCategoriesAndDoNotExposeRawErrors() async throws {
        let connection = ControlledGeminiConnection()
        let translator = GeminiLiveTranslator { _ in connection }
        defer { translator.close() }
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-key")
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .configured)
        connection.deliver(Data(#"{"error":{"code":403,"message":"synthetic-key https://secret.example?key=synthetic-key"}}"#.utf8))
        do { _ = try await iterator.next(); Issue.record("Credential failure was silently completed") }
        catch { #expect(error as? AudioProcessingError == .credential) }
        #expect(connection.isClosed)
    }

    @Test func cancellingFinishingStopsProtocolSilenceWithoutSendingAnEndMarker() async throws {
        let connection = ControlledGeminiConnection()
        let translator = GeminiLiveTranslator { _ in connection }
        defer { translator.close() }
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-key")
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .configured)
        try await translator.finishInput()
        #expect(connection.sent.count == 1 && translator.finishingSilenceFramesSent == 0)
        try await translator.append(LiveAudioChunk(pcm16: Data(repeating: 7, count: 4800), recordingStartFrame: 0))
        let finishing = Task { @MainActor in try await translator.finishInput() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while translator.finishingSilenceFramesSent == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(translator.finishingSilenceFramesSent > 0)
        finishing.cancel()
        do { try await finishing.value; Issue.record("Cancelled finishing succeeded") }
        catch { #expect(error is CancellationError) }
        let sentCount = connection.sent.count
        try await Task.sleep(for: .milliseconds(120))
        #expect(connection.sent.count == sentCount && connection.isClosed)
        let messages = try connection.sent.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(!messages.contains { ($0?["realtimeInput"] as? [String: Bool])?["audioStreamEnd"] == true })
    }

    @Test func replacingAConnectionDuringFinishingCannotSendTheOldEndToTheNewConnection() async throws {
        let old = ControlledGeminiConnection(), current = ControlledGeminiConnection()
        var connections = [old, current]
        let translator = GeminiLiveTranslator { _ in connections.removeFirst() }
        defer { translator.close() }
        let first = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-key")
        var oldIterator = first.makeAsyncIterator()
        #expect(try await oldIterator.next() == .configured)
        try await translator.append(LiveAudioChunk(pcm16: Data(repeating: 7, count: 4800), recordingStartFrame: 0))
        let finishing = Task { @MainActor in try await translator.finishInput() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while translator.finishingSilenceFramesSent == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(translator.finishingSilenceFramesSent > 0)
        let second = try await translator.connect(configuration: .init(provider: .gemini), direction: .chineseToEnglish, apiKey: "new-synthetic-key")
        var currentIterator = second.makeAsyncIterator()
        #expect(try await currentIterator.next() == .configured)
        do { try await finishing.value; Issue.record("Stale finishing succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(current.sent.count == 1 && !current.isClosed && translator.finishingSilenceFramesSent == 0)
        try await translator.append(LiveAudioChunk(pcm16: Data(repeating: 9, count: 4800), recordingStartFrame: 0))
        #expect(!current.isClosed)
    }

    @Test func captureGapStopsDeliveryAndLeavesOriginalChunkUntouched() async throws {
        let connection = ControlledGeminiConnection()
        let translator = GeminiLiveTranslator { _ in connection }
        defer { translator.close() }
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-key")
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .configured)
        let original = try LiveAudioChunk(pcm16: Data(repeating: 7, count: 4800), recordingStartFrame: 48_000)
        try await translator.append(original)
        let sentBeforeGap = connection.sent.count
        do {
            try await translator.append(LiveAudioChunk(pcm16: original.pcm16, recordingStartFrame: original.recordingEndFrame + 1))
            Issue.record("A missing input frame was silently skipped")
        } catch { #expect(error as? AudioProcessingError == .processing) }
        #expect(connection.sent.count == sentBeforeGap)
        #expect(original.pcm16 == Data(repeating: 7, count: 4800) && original.recordingStartFrame == 48_000)
        #expect(connection.isClosed)
    }

    @Test func setupTimeoutRejectsPrematureAudioAndEndsWithTypedFailure() async throws {
        let connection = ControlledGeminiConnection()
        connection.automaticallyConfigures = false
        let translator = GeminiLiveTranslator(operationTimeout: 0.02) { _ in connection }
        defer { translator.close() }
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-key")
        do {
            try await translator.append(LiveAudioChunk(pcm16: Data(repeating: 0, count: 4800), recordingStartFrame: 0))
            Issue.record("Audio was sent before setupComplete")
        } catch { #expect(error as? AudioProcessingError == .unavailable) }
        var iterator = stream.makeAsyncIterator()
        do { _ = try await iterator.next(); Issue.record("Setup timeout was silently completed") }
        catch { #expect(error as? AudioProcessingError == .unavailable) }
        #expect(connection.sent.count == 1 && connection.isClosed)
    }

    @Test func lateCancelledConnectionCannotCloseOrContaminateReplacement() async throws {
        let old = ControlledGeminiConnection(), current = ControlledGeminiConnection()
        old.holdsFirstSend = true
        old.failureDiagnostics = .init(httpStatus: 101, webSocketCloseCode: 1008)
        var connections = [old, current]
        let translator = GeminiLiveTranslator { _ in connections.removeFirst() }
        defer { translator.close(); old.releaseSend() }
        let oldConnect = Task { @MainActor in
            try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "old-synthetic-key")
        }
        await old.waitForSend()
        let stream = try await translator.connect(configuration: .init(provider: .gemini), direction: .chineseToEnglish, apiKey: "new-synthetic-key")
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .configured)
        old.deliver(Data(#"{"serverContent":{"outputTranscription":{"text":"late old text"}}}"#.utf8))
        old.releaseSend()
        do { _ = try await oldConnect.value; Issue.record("Stale connect succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(translator.latestFailureDiagnostics == nil)
        current.deliver(Data(#"{"serverContent":{"outputTranscription":{"text":"current"}}}"#.utf8))
        guard case .text(.translation, _, "current", nil, nil, nil) = try await iterator.next() else {
            Issue.record("Replacement stream was contaminated"); return
        }
        #expect(old.isClosed && !current.isClosed)
    }

    @Test func rawNetworkFailureAndInvalidTargetNeverExposeCredentialsOrFallback() async throws {
        let connection = ControlledGeminiConnection()
        connection.sendError = NSError(domain: "synthetic-key https://example.test?key=synthetic-key", code: 123)
        connection.failureDiagnostics = .init(httpStatus: 101, webSocketCloseCode: 1008)
        let replacement = ControlledGeminiConnection()
        var attempts = 0
        let translator = GeminiLiveTranslator { _ in attempts += 1; return attempts == 1 ? connection : replacement }
        defer { translator.close() }
        do {
            _ = try await translator.connect(configuration: .init(provider: .openAI), direction: .englishToChinese, apiKey: "synthetic-key")
            Issue.record("Unsupported provider connected")
        } catch { #expect(error as? AudioProcessingError == .configuration) }
        #expect(attempts == 0)
        do {
            _ = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-key")
            Issue.record("Raw transport failure was accepted")
        } catch { #expect(error as? AudioProcessingError == .unavailable) }
        #expect(attempts == 1 && connection.isClosed)
        #expect(translator.latestFailureDiagnostics == .init(httpStatus: 101, webSocketCloseCode: 1008))
        translator.close()
        #expect(translator.latestFailureDiagnostics == .init(httpStatus: 101, webSocketCloseCode: 1008))
        _ = try await translator.connect(configuration: .init(provider: .gemini), direction: .englishToChinese, apiKey: "synthetic-key")
        #expect(translator.latestFailureDiagnostics == nil)
    }
}

@MainActor private final class ControlledGeminiConnection: GeminiWebSocketConnection {
    var sent: [Data] = []
    var automaticallyConfigures = true
    var holdsFirstSend = false
    var sendError: Error?
    var failureDiagnostics: GeminiTransportFailureDiagnostics?
    private var pendingSend: CheckedContinuation<Void, Never>?
    private var sendObserver: CheckedContinuation<Void, Never>?
    private var queued: [Data] = []
    private var pending: CheckedContinuation<Data?, Error>?
    private(set) var isClosed = false
    func send(_ data: Data) async throws {
        sent.append(data)
        if let sendError { throw sendError }
        if sent.count == 1 && automaticallyConfigures { deliver(Data(#"{"setupComplete":{}}"#.utf8)) }
        if sent.count == 1 && holdsFirstSend {
            await withCheckedContinuation { pendingSend = $0; sendObserver?.resume(); sendObserver = nil }
        }
    }
    func waitForSend() async {
        if pendingSend != nil { return }
        await withCheckedContinuation { sendObserver = $0 }
    }
    func releaseSend() { pendingSend?.resume(); pendingSend = nil }
    func receive() async throws -> Data? {
        if !queued.isEmpty { return queued.removeFirst() }
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func deliver(_ data: Data) {
        if let pending { self.pending = nil; pending.resume(returning: data) }
        else { queued.append(data) }
    }
    func close() {
        isClosed = true
        pending?.resume(returning: nil); pending = nil
    }
}
