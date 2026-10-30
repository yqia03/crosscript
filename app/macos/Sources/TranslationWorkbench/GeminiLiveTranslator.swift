import AVFoundation
import WorkbenchCore

struct GeminiTransportFailureDiagnostics: Equatable, Sendable {
    let httpStatus: Int?
    let webSocketCloseCode: Int?
}

/// The only injectable boundary is the external connection. PCM conversion and
/// wire parsing still run in controlled tests, exactly as in production.
@MainActor protocol GeminiWebSocketConnection: AnyObject {
    var failureDiagnostics: GeminiTransportFailureDiagnostics? { get }
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func close()
}

extension GeminiWebSocketConnection {
    var failureDiagnostics: GeminiTransportFailureDiagnostics? { nil }
}

private final class GeminiRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor private final class GeminiURLSessionConnection: GeminiWebSocketConnection {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    var failureDiagnostics: GeminiTransportFailureDiagnostics? {
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        let validStatus = status.flatMap { (100...599).contains($0) ? $0 : nil }
        let code = socket.closeCode.rawValue
        let validCode = (1000...4999).contains(code) ? code : nil
        guard validStatus != nil || validCode != nil else { return nil }
        return .init(httpStatus: validStatus, webSocketCloseCode: validCode)
    }
    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        session = URLSession(configuration: configuration, delegate: GeminiRedirectGuard(), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 16_777_216
        socket.resume()
    }
    func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { throw AudioProcessingError.processing }
        do { try await socket.send(.string(text)) }
        catch { throw failure() }
    }
    func receive() async throws -> Data? {
        do {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: throw AudioProcessingError.processing
            }
        } catch {
            if socket.closeCode == .normalClosure { return nil }
            throw failure()
        }
    }
    private func failure() -> AudioProcessingError {
        switch (socket.response as? HTTPURLResponse)?.statusCode {
        case 400: return .configuration
        case 401, 403: return .credential
        case 404: return .modelUnavailable
        case 429: return .rateLimited
        default: return .unavailable
        }
    }
    func close() { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

/// One fixed Gemini target, one explicit connection, no retry or fallback.
/// Output audio is decoded only to count and discard it; it is never played.
@MainActor final class GeminiLiveTranslator: LiveBilingualTranslating {
    private(set) var latestFailureDiagnostics: GeminiTransportFailureDiagnostics?
    /// Successful 16 kHz protocol-silence frames, excluded from original media.
    private(set) var finishingSilenceFramesSent: Int64 = 0
    private let makeConnection: @MainActor (URLRequest) -> any GeminiWebSocketConnection
    private let operationTimeout: TimeInterval
    private var socket: (any GeminiWebSocketConnection)?
    private var wire: GeminiLiveTranslationProtocol?
    private var reader: Task<Void, Never>?
    private var setupDeadline: Task<Void, Never>?
    private var generation = UUID()
    private var continuation: AsyncThrowingStream<LiveBilingualTransportEvent, Error>.Continuation?
    private var configured = false
    private var writing = false
    private var expectedFrame: Int64?
    private var lastFinishedFrame: Int64?
    private var conversion: GeminiPCMConversion?
    private var pendingPCM = Data()

    init(operationTimeout: TimeInterval = 12,
         makeConnection: @escaping @MainActor (URLRequest) -> any GeminiWebSocketConnection = { GeminiURLSessionConnection(request: $0) }) {
        self.operationTimeout = operationTimeout; self.makeConnection = makeConnection
    }

    func connect(configuration: AudioServiceConfiguration, direction: TextTranslationDirection,
                 apiKey: String) async throws -> AsyncThrowingStream<LiveBilingualTransportEvent, Error> {
        close()
        latestFailureDiagnostics = nil
        finishingSilenceFramesSent = 0
        let wire = try GeminiLiveTranslationProtocol(configuration: configuration, direction: direction)
        guard operationTimeout.isFinite, operationTimeout > 0 else { throw AudioProcessingError.configuration }
        guard !apiKey.isEmpty, apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AudioProcessingError.credential }
        let token = generation
        var request = URLRequest(url: wire.webSocketURL, timeoutInterval: operationTimeout)
        // Official SDK sends this header on the key-free BidiGenerateContent URL.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let socket = makeConnection(request)
        self.socket = socket; self.wire = wire
        let pair = AsyncThrowingStream<LiveBilingualTransportEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuation = pair.continuation
        reader = Task { @MainActor [weak self] in
            var decoder = wire
            do {
                while !Task.isCancelled {
                    let data = try await socket.receive()
                    guard let self, self.generation == token else { return }
                    guard let data else {
                        if case .dropped = pair.continuation.yield(.closed) { throw AudioProcessingError.processing }
                        self.end(token: token, error: nil); return
                    }
                    for event in try decoder.events(data) {
                        if event == .configured {
                            self.configured = true
                            self.setupDeadline?.cancel(); self.setupDeadline = nil
                        }
                        if case .dropped = pair.continuation.yield(event) { throw AudioProcessingError.processing }
                    }
                }
            } catch { self?.end(token: token, error: Self.safe(error)) }
        }
        do { try await send(wire.setupMessage(), token: token) }
        catch { end(token: token, error: Self.safe(error)); throw Self.safe(error) }
        if !configured {
            let timeout = operationTimeout
            setupDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.end(token: token, error: AudioProcessingError.unavailable)
            }
        }
        return pair.stream
    }

    func append(_ chunk: LiveAudioChunk) async throws {
        guard configured, !writing, let wire else { throw AudioProcessingError.unavailable }
        let token = generation
        writing = true
        defer { if generation == token { writing = false } }
        do {
            guard expectedFrame == nil || expectedFrame == chunk.recordingStartFrame else { throw AudioProcessingError.processing }
            if conversion == nil { conversion = try GeminiPCMConversion() }
            pendingPCM.append(try conversion!.append(chunk.pcm16))
            expectedFrame = chunk.recordingEndFrame
            try await sendPackets(wire: wire, token: token, flush: false)
        } catch { end(token: token, error: Self.safe(error)); throw Self.safe(error) }
    }

    func finishInput() async throws {
        try await finishInput(silencePackets: 40)
    }

    func pauseInput() async throws {
        try await finishInput(silencePackets: 6)
    }

    private func finishInput(silencePackets: Int) async throws {
        guard configured, !writing, let wire else { throw AudioProcessingError.unavailable }
        guard let endFrame = expectedFrame, endFrame != lastFinishedFrame else { return }
        let token = generation
        writing = true
        defer { if generation == token { writing = false } }
        do {
            if let conversion { pendingPCM.append(try conversion.finish()) }
            conversion = nil
            try await sendPackets(wire: wire, token: token, flush: true)
            // Live Translate can retain its last words after audioStreamEnd.
            // Advance only the service audio clock with a bounded, real-time
            // silence tail. Pause uses a shorter tail so it can release its
            // connection promptly. Original PCM is fully flushed in both paths;
            // protocol silence never changes the recording or its frame clock.
            let silence = try wire.audioMessage(Data(repeating: 0, count: 3200))
            for _ in 0..<silencePackets {
                try await send(silence, token: token)
                finishingSilenceFramesSent += 1600
                try await Task.sleep(for: .milliseconds(100))
            }
            try await send(wire.finishInputMessage(), token: token)
            lastFinishedFrame = endFrame
            // The API permits later audio to reopen its stream. Neither this send
            // nor a server turn marker confirms consumption of the local tail.
        } catch { end(token: token, error: Self.safe(error)); throw Self.safe(error) }
    }

    private func sendPackets(wire: GeminiLiveTranslationProtocol, token: UUID, flush: Bool) async throws {
        while pendingPCM.count >= 3200 || (flush && !pendingPCM.isEmpty) {
            let count = min(3200, pendingPCM.count)
            let packet = Data(pendingPCM.prefix(count))
            pendingPCM.removeFirst(count)
            try await send(wire.audioMessage(packet), token: token)
        }
    }
    private func send(_ data: Data, token: UUID) async throws {
        try Task.checkCancellation()
        guard generation == token, let socket else { throw CancellationError() }
        let timeout = operationTimeout
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.end(token: token, error: AudioProcessingError.unavailable)
        }
        defer { deadline.cancel() }
        do { try await socket.send(data) } catch { throw Self.safe(error) }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private static func safe(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        return (error as? AudioProcessingError) ?? AudioProcessingError.unavailable
    }
    private func end(token: UUID, error: Error?) {
        guard generation == token else { return }
        if error != nil { latestFailureDiagnostics = socket?.failureDiagnostics }
        let continuation = self.continuation
        self.continuation = nil
        close()
        continuation?.finish(throwing: error)
    }
    func close() {
        generation = UUID()
        reader?.cancel(); reader = nil
        setupDeadline?.cancel(); setupDeadline = nil
        socket?.close(); socket = nil
        continuation?.finish(); continuation = nil
        wire = nil; configured = false; writing = false
        expectedFrame = nil; lastFinishedFrame = nil; conversion = nil; pendingPCM = Data()
    }
}

/// Stateful native resampling, with final output bounded to the input duration.
/// This operates on a copy after the original 24 kHz recording write succeeded.
private final class GeminiPCMConversion {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var inputFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    init() throws {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { throw AudioProcessingError.processing }
        inputFormat = input; outputFormat = output; self.converter = converter
        converter.primeMethod = .none
    }
    func append(_ data: Data) throws -> Data {
        let frames = AVAudioFrameCount(data.count / 2)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let destination = input.int16ChannelData?[0] else { throw AudioProcessingError.processing }
        input.frameLength = frames
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: data.count))
        inputFrames += Int64(frames)
        var supplied = false
        return try convert(capacity: AVAudioFrameCount(ceil(Double(frames) * 2 / 3) + 64)) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }.data
    }
    func finish() throws -> Data {
        var result = Data()
        // AVAudioConverter's filter is finite; bound draining even if a platform
        // unexpectedly fails to report endOfStream.
        for _ in 0..<8 {
            let converted = try convert(capacity: 4096, finishing: true) { _, status in
                status.pointee = .endOfStream; return nil
            }
            result.append(converted.data)
            if converted.status == .endOfStream { return result }
        }
        throw AudioProcessingError.processing
    }
    private func convert(capacity: AVAudioFrameCount, finishing: Bool = false,
                         input: @escaping AVAudioConverterInputBlock) throws -> (data: Data, status: AVAudioConverterOutputStatus) {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw AudioProcessingError.processing }
        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: input)
        guard error == nil, status != .error, let samples = output.int16ChannelData?[0] else { throw AudioProcessingError.processing }
        let frames = finishing ? min(Int64(output.frameLength), max(0, (inputFrames * 2 + 2) / 3 - outputFrames)) : Int64(output.frameLength)
        outputFrames += frames
        return (Data(bytes: samples, count: Int(frames) * 2), status)
    }
}
