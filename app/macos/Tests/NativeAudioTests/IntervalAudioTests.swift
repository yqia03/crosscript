import AVFoundation
import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite struct IntervalAudioTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func slicesOnlySelectedMediaRangeAndMapsProviderTimesToOriginal(rate: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-slice-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.caf")
        try writeAudio(input, rate: rate)
        let original = try Data(contentsOf: input)
        let interval = MissingInterval(startFrame: 24_000, endFrame: 48_000)
        let service = InspectingRangeService()
        let result = try await FileIntervalTranscriber(service: service).transcribe(audio: input, interval: interval,
            configuration: .init(provider: .aiHubMix, model: "whisper-1"), apiKey: "controlled")
        #expect(result.text == "middle only")
        #expect(result.anchors.first?.sourceStart == 1.25)
        #expect(result.anchors.first?.sourceEnd == 1.75)
        #expect(try Data(contentsOf: input) == original)
        let output = root.appendingPathComponent("empty.caf")
        #expect(throws: AudioProcessingError.unsupportedAudio) {
            try FileIntervalTranscriber.cut(audio: input, interval: .init(startFrame: 24_000, endFrame: 96_000), to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: AudioProcessingError.configuration) { try FileIntervalTranscriber.cut(audio: input, interval: interval, to: input) }
        #expect(try Data(contentsOf: input) == original)
    }
    private func writeAudio(_ url: URL, rate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 3)))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = i < Int(rate) ? 0.1 : i < Int(rate * 2) ? 0.5 : 0.9 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
private struct InspectingRangeService: FileTranscribing {
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, progress: @escaping @Sendable (Int) async -> Void) async throws -> String { throw AudioProcessingError.processing }
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
        progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        #expect(requestTimestamps)
        let file = try AVAudioFile(forReading: audio)
        #expect(Double(file.length) / file.processingFormat.sampleRate == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        #expect((0..<Int(buffer.frameLength)).allSatisfy { abs(buffer.floatChannelData![0][$0] - 0.5) < 0.001 })
        return .init(text: "middle only", anchors: [.init(sourceStart: 0.25, sourceEnd: 0.75, range: .init(location: 0, length: 11))])
    }
}
