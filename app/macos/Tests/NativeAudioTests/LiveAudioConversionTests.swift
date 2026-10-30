import AVFoundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

struct LiveAudioConversionTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func capturedBuffersBecomeContinuousMonoPCMOnTheMediaClock(sampleRate: Double) throws {
        let received = CapturedLiveChunks()
        let conversion = LiveAudioConversion { received.add($0) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 2, interleaved: false))
        let size = AVAudioFrameCount(sampleRate / 10)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size))
        buffer.frameLength = size
        for channel in 0..<2 {
            for index in 0..<Int(size) { buffer.floatChannelData![channel][index] = 0.25 }
        }
        for _ in 0..<10 { conversion.append(buffer) }
        let chunks = received.chunks
        #expect(!chunks.isEmpty)
        #expect(chunks.first?.recordingStartFrame == 0)
        // The native resampler may retain its filter tail; it must not invent
        // wall-clock gaps or lose more than one capture buffer at the boundary.
        let end = try #require(chunks.last?.recordingEndFrame)
        #expect(end > 21_600 && end <= 24_000)
        for (left, right) in zip(chunks, chunks.dropFirst()) {
            #expect(left.recordingEndFrame == right.recordingStartFrame)
        }
        #expect(chunks.allSatisfy { $0.pcm16.count <= 48_000 && $0.pcm16.count % 2 == 0 })
        #expect(chunks.contains { $0.pcm16.contains(where: { $0 != 0 }) })
    }

    @Test func conversionFailureIsReportedOnceAndNeverCallsRecordingFailure() throws {
        let received = CapturedLiveChunks()
        let failed = CapturedLiveFailures()
        let conversion = LiveAudioConversion(receive: { received.add($0) }, onFailure: { failed.add($0) })
        let firstFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 1, interleaved: false))
        let changedFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100, channels: 1, interleaved: false))
        let initial = try #require(AVAudioPCMBuffer(pcmFormat: firstFormat, frameCapacity: 4800))
        initial.frameLength = 4800
        for index in 0..<4800 { initial.floatChannelData![0][index] = 0 }
        conversion.append(initial)
        let validCount = received.chunks.count
        let changed = try #require(AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 4410))
        changed.frameLength = 4410
        conversion.append(changed)
        conversion.append(changed)
        conversion.append(initial)
        #expect(validCount > 0)
        #expect(received.chunks.count == validCount)
        #expect(failed.count == 1)
    }

    @Test func largeCapturedBufferSplitsWithoutDuplicatingOrDroppingOccurrences() throws {
        let received = CapturedLiveChunks()
        let conversion = LiveAudioConversion { received.add($0) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000))
        buffer.frameLength = 120_000
        for index in 0..<120_000 { buffer.floatChannelData![0][index] = 0 }
        conversion.append(buffer)
        let chunks = received.chunks
        #expect(chunks.count == 3)
        #expect(chunks.map(\.recordingStartFrame) == [0, 24_000, 48_000])
        #expect(chunks.reduce(0) { $0 + $1.pcm16.count } == Int(chunks.last!.recordingEndFrame) * 2)
    }
}

private final class CapturedLiveChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LiveAudioChunk] = []
    func add(_ chunk: LiveAudioChunk) { lock.lock(); defer { lock.unlock() }; values.append(chunk) }
    var chunks: [LiveAudioChunk] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class CapturedLiveFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Error] = []
    func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; values.append(error) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
