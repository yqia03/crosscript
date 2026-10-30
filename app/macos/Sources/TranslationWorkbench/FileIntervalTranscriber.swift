import AVFoundation
import Foundation
import WorkbenchCore

/// Reads only the requested source range into a private temporary CAF. Existing
/// file STT handles upload limits; no full original recording is retransmitted.
struct FileIntervalTranscriber: IntervalTranscribing {
    let service: any FileTranscribing
    init(service: any FileTranscribing = OpenAIFileTranscriber()) { self.service = service }
    func transcribe(audio: URL, interval: MissingInterval, configuration: AudioServiceConfiguration, apiKey: String) async throws -> TranscribedAudio {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-repair-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("range.caf")
        let cut = Task.detached(priority: .utility) { try Self.cut(audio: audio, interval: interval, to: destination) }
        let offset = try await withTaskCancellationHandler { try await cut.value } onCancel: { cut.cancel() }
        try Task.checkCancellation()
        let result = try await service.transcribeDocument(audio: destination, configuration: configuration, apiKey: apiKey,
            requestTimestamps: true, progress: { _ in })
        try Task.checkCancellation()
        let anchors = result.anchors.map { anchor in
            var value = TranscriptAnchor(id: anchor.id, sourceStart: offset + anchor.sourceStart,
                sourceEnd: offset + anchor.sourceEnd, range: anchor.range, chunkStartFrame: interval.startFrame)
            value.isStartReliable = anchor.isStartReliable
            return value
        }
        return .init(text: result.text, anchors: anchors)
    }
    static func cut(audio: URL, interval: MissingInterval, to destination: URL) throws -> TimeInterval {
        guard interval.startFrame >= 0, interval.endFrame > interval.startFrame,
              audio.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else { throw AudioProcessingError.configuration }
        let input = try AVAudioFile(forReading: audio)
        let rate = input.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, interval.end <= Double(input.length) / rate + 0.001 else { throw AudioProcessingError.unsupportedAudio }
        let start = AVAudioFramePosition((interval.start * rate).rounded(.down))
        let end = min(input.length, AVAudioFramePosition((interval.end * rate).rounded(.up)))
        guard end > start, let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else { throw AudioProcessingError.unsupportedAudio }
        input.framePosition = start
        let output = try AVAudioFile(forWriting: destination, settings: input.processingFormat.settings,
            commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
        while input.framePosition < end {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), end - input.framePosition)))
            guard buffer.frameLength > 0 else { throw AudioProcessingError.unsupportedAudio }
            try output.write(from: buffer)
        }
        return Double(start) / rate
    }
}
