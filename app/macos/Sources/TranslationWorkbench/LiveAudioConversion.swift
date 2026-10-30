import AVFoundation
import WorkbenchCore

/// Confined to the capture writer's serial execution. Conversion failure only
/// disables live delivery; the caller has already persisted the original audio.
enum LiveAudioConversionError: Error, Sendable { case unsupportedFormat, allocation, conversion, invalidChunk }

final class LiveAudioConversion {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var nextFrame: Int64 = 0
    private var unavailable = false
    private let onFailure: (@Sendable (Error) -> Void)?
    private let receive: @Sendable (LiveAudioChunk) -> Void
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: 24_000, channels: 1, interleaved: true)!

    init(receive: @escaping @Sendable (LiveAudioChunk) -> Void, onFailure: (@Sendable (Error) -> Void)?) {
        self.receive = receive
        self.onFailure = onFailure
    }
    convenience init(receive: @escaping @Sendable (LiveAudioChunk) -> Void) {
        self.init(receive: receive, onFailure: nil)
    }
    private func fail(_ error: LiveAudioConversionError) {
        guard !unavailable else { return }
        unavailable = true
        onFailure?(error)
    }

    func append(_ input: AVAudioPCMBuffer) {
        guard !unavailable, input.frameLength > 0 else { return }
        if converter == nil {
            inputFormat = input.format
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard input.format == inputFormat, let converter else { fail(.unsupportedFormat); return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            fail(.allocation); return
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, status != .error else { fail(.conversion); return }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(output.frameLength) * 2)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 48_000)
            guard let chunk = try? LiveAudioChunk(pcm16: data.subdata(in: offset..<end), recordingStartFrame: nextFrame) else {
                fail(.invalidChunk); return
            }
            nextFrame = chunk.recordingEndFrame
            receive(chunk)
            offset = end
        }
    }
}
