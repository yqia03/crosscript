import AVFoundation
import Foundation
import WorkbenchCore

struct NativeAudioImporter: AudioImporting {
    func copyAudio(from source: URL, to destination: URL) async throws -> TimeInterval {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .utility) {
            do {
                try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
                let asset = AVURLAsset(url: destination)
                guard try await asset.loadTracks(withMediaType: .video).isEmpty else { throw AudioProcessingError.unsupportedAudio }
                let file = try AVAudioFile(forReading: destination)
                guard file.length > 0, file.processingFormat.sampleRate > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                    throw AudioProcessingError.unsupportedAudio
                }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw AudioProcessingError.unsupportedAudio }
                return Double(file.length) / file.processingFormat.sampleRate
            } catch let error as AudioProcessingError { throw error }
            catch let error as CocoaError where [.fileWriteOutOfSpace, .fileWriteNoPermission].contains(error.code) {
                throw AudioProcessingError.storage
            } catch { throw AudioProcessingError.unsupportedAudio }
        }.value
    }
}

/// Bounded conversion buffer; the original file is always opened read-only.
/// Chunk boundaries prefer a quiet 300 ms interval in the final 30 seconds.
final class AudioChunkReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var pending = Data()
    private var finished = false
    private let maximumBytes = 16_000 * 2 * 600

    init(url: URL) throws {
        do {
            file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw AudioProcessingError.unsupportedAudio }
            self.converter = converter
            self.input = input
            self.output = output
        } catch { throw AudioProcessingError.unsupportedAudio }
    }

    func next() throws -> Data? {
        while pending.count < maximumBytes && !finished {
            try Task.checkCancellation()
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { [self] requested, state in
                guard file.framePosition < file.length else {
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            guard readError == nil, conversionError == nil, status != .error else { throw AudioProcessingError.unsupportedAudio }
            if let bytes = output.int16ChannelData?[0], output.frameLength > 0 {
                pending.append(UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: Int(output.frameLength) * 2))
            }
            if status == .endOfStream { finished = true }
        }
        guard !pending.isEmpty else { return nil }
        let size = pending.count >= maximumBytes ? quietBoundary() : pending.count
        let pcm = Data(pending.prefix(size))
        pending.removeFirst(size)
        return wav(pcm)
    }

    private func quietBoundary() -> Int {
        let windowBytes = 4800 * 2
        // Search backwards so quiet recordings still use most of the upload budget.
        return pending.withUnsafeBytes { raw in
            for end in stride(from: maximumBytes, through: maximumBytes - 30 * 32_000, by: -windowBytes) {
                var peak: Int = 0
                for offset in stride(from: end - windowBytes, to: end, by: 2) {
                    let value = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                    peak = max(peak, abs(value))
                }
                if peak < 327 { return end }
            }
            return maximumBytes
        }
    }

    private func wav(_ pcm: Data) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF"); integer(UInt32(pcm.count + 36)); text("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(16_000)); integer(UInt32(32_000)); integer(UInt16(2)); integer(UInt16(16))
        text("data"); integer(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
