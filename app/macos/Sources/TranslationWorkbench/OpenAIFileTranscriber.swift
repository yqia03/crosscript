import Foundation
import CoreFoundation
import WorkbenchCore

private final class AudioRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward audio or credentials to a redirect target.
        completionHandler(nil)
    }
}

struct OpenAIFileTranscriber: FileTranscribing {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration, delegate: AudioRedirectPolicy(), delegateQueue: nil)
        }
    }

    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String {
        try await transcribeDocument(audio: audio, configuration: configuration, apiKey: apiKey,
                                     requestTimestamps: false, progress: progress).text
    }

    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                            requestTimestamps: Bool, progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        let configuration = try configuration.validated()
        guard !requestTimestamps || configuration.supportsSegmentTimestamps else { throw AudioProcessingError.configuration }
        let work = Task.detached(priority: .utility) {
            let chunks = try AudioChunkReader(url: audio)
            var text = ""
            var anchors: [TranscriptAnchor] = []
            var count = 0
            var uploadedFrames: Int64 = 0
            while let wav = try chunks.next() {
                try Task.checkCancellation()
                guard wav.count < 25_000_000 else { throw AudioProcessingError.processing }
                let result = try await upload(wav, configuration: configuration, apiKey: apiKey,
                                              requestTimestamps: requestTimestamps, chunkNumber: count + 1)
                if count > 0 { text += "\n\n" }
                let offset = text.utf16.count
                // Quiet cuts are variable length. WAV is PCM16 mono at 16 kHz;
                // count the actual uploaded frames, excluding the 44-byte header.
                let chunkStart = Double(uploadedFrames) / 16_000
                anchors += result.anchors.map {
                    TranscriptAnchor(id: $0.id, sourceStart: chunkStart + $0.sourceStart, sourceEnd: chunkStart + $0.sourceEnd,
                                     range: TranscriptTextRange(location: offset + $0.range.location, length: $0.range.length),
                                     chunkStartFrame: uploadedFrames)
                }
                text += result.text
                uploadedFrames += Int64((wav.count - 44) / 2)
                count += 1
                await progress(count)
            }
            guard count > 0 else { throw AudioProcessingError.unsupportedAudio }
            return TranscribedAudio(text: text, anchors: anchors)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func upload(_ wav: Data, configuration: AudioServiceConfiguration, apiKey: String,
                        requestTimestamps: Bool, chunkNumber: Int) async throws -> TranscribedAudio {
        let boundary = "workbench-" + UUID().uuidString
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(configuration.model)\r\n")
        let diarized = configuration.provider == .openAI && configuration.model == "gpt-4o-transcribe-diarize"
        let responseFormat = requestTimestamps ? (diarized ? "diarized_json" : "verbose_json") : "json"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\n\(responseFormat)\r\n")
        if diarized {
            // Required by this model for files longer than 30 seconds, including
            // each independently uploaded portion of a longer recording.
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chunking_strategy\"\r\n\r\nauto\r\n")
        } else if requestTimestamps {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: try configuration.transcriptionURL())
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        let started = ProcessInfo.processInfo.systemUptime
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            let failure = error as NSError
            guard failure.domain == NSURLErrorDomain else { throw AudioProcessingError.unavailable }
            throw AudioRequestFailure(category: .unavailable,
                diagnostics: AudioFailureDiagnostics(origin: .transport, code: failure.code,
                    failedChunk: chunkNumber, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started))
        }
        guard let response = response as? HTTPURLResponse else { throw AudioProcessingError.processing }
        if !(200..<300).contains(response.statusCode) {
            let category: AudioProcessingError
            if let failure = classifiedError(data, status: response.statusCode, provider: configuration.provider) {
                category = failure
            } else {
                switch response.statusCode {
                case 300..<400: category = .configuration
                case 401, 403: category = .credential
                case 404, 500...599: category = .unavailable
                case 429: category = .rateLimited
                default: category = .processing
                }
            }
            throw AudioRequestFailure(category: category,
                diagnostics: AudioFailureDiagnostics(origin: .http, code: response.statusCode,
                    failedChunk: chunkNumber, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started))
        }
        struct Response: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else { throw AudioProcessingError.processing }
        guard requestTimestamps else { return TranscribedAudio(text: result.text) }
        return timedTranscript(text: result.text, data: data, duration: Double(wav.count - 44) / 32_000, diarized: diarized)
    }

    private func timedTranscript(text: String, data: Data, duration: TimeInterval, diarized: Bool) -> TranscribedAudio {
        let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let segments = response?["segments"] as? [[String: Any]] ?? []
        let original = text as NSString
        var cursor = 0
        var previousEnd: TimeInterval = 0
        var anchors: [TranscriptAnchor] = []
        for segment in segments {
            guard let source = segment["text"] as? String else { continue }
            let content = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let range = original.range(of: content, options: .literal, range: NSRange(location: cursor, length: original.length - cursor))
            guard range.location != NSNotFound else { continue }
            let previousTextEnd = cursor
            cursor = NSMaxRange(range)
            // A partial segment list cannot identify which occurrence of repeated
            // text was timed. Preserve the words, but don't guess the occurrence.
            let first = original.range(of: content, options: .literal)
            let rest = NSRange(location: NSMaxRange(first), length: original.length - NSMaxRange(first))
            guard original.range(of: content, options: .literal, range: rest).location == NSNotFound else { continue }
            guard let start = timestamp(segment["start"]), let end = timestamp(segment["end"]),
                  start.isFinite, end.isFinite, start >= previousEnd, end > start,
                  end <= duration, start < duration else { continue }
            let mappedRange: NSRange
            if diarized {
                guard let labeledRange = diarizedRange(in: original, contentRange: range,
                    previousTextEnd: previousTextEnd, speaker: segment["speaker"] as? String) else { continue }
                mappedRange = labeledRange
            } else { mappedRange = range }
            anchors.append(TranscriptAnchor(sourceStart: start, sourceEnd: end,
                range: TranscriptTextRange(location: mappedRange.location, length: mappedRange.length)))
            previousEnd = end
        }
        return TranscribedAudio(text: text, anchors: anchors)
    }

    private func diarizedRange(in text: NSString, contentRange: NSRange, previousTextEnd: Int, speaker: String?) -> NSRange? {
        let gap = NSRange(location: previousTextEnd, length: contentRange.location - previousTextEnd)
        let prefix = text.substring(with: gap).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return contentRange }
        // Some diarized responses label the combined text ("A: Hello") while
        // segment.text only contains "Hello". Keep the returned text intact and
        // include only a confirmed speaker label in that source interval.
        guard let speaker, !speaker.isEmpty, prefix.caseInsensitiveCompare(speaker + ":") == .orderedSame else { return nil }
        let labelStart = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: [], range: gap).location
        return NSRange(location: labelStart, length: NSMaxRange(contentRange) - labelStart)
    }

    private func timestamp(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private func classifiedError(_ data: Data, status: Int, provider: AudioServiceProvider) -> AudioProcessingError? {
        // Decode only an allowlisted code, never the provider's message (which can contain key fragments).
        struct Envelope: Decodable {
            struct Detail: Decodable { let code: String? }
            let error: Detail
        }
        guard data.count <= 65_536, let code = try? JSONDecoder().decode(Envelope.self, from: data).error.code else { return nil }
        switch (status, code) {
        case (403, "insufficient_user_quota") where provider == .aiHubMix: return .quotaExceeded
        case (429, "insufficient_quota"): return .quotaExceeded
        case (429, "rate_limit_exceeded"): return .requestLimited
        case (400, "model_not_found"), (404, "model_not_found"): return .modelUnavailable
        default: return nil
        }
    }
}
