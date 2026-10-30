import AVFoundation
import Foundation
import WorkbenchCore

private struct AudioInspectionError: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        AppLanguage.current.text(
            "无法读取此前保存的音频。现有资料已保留；请检查文件和磁盘，修正后从历史资料刷新重试。",
            "Previously saved audio could not be read. Existing material was retained. Check the file and disk, then refresh History to retry.")
        + "\n" + underlying.localizedDescription
    }
}

enum AudioFileInspection {
    // Opening for reading never finalizes, repairs, or rewrites original audio.
    static func duration(at url: URL) throws -> TimeInterval {
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            guard rate.isFinite, rate > 0, file.length >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Double(file.length) / rate
        } catch {
            throw AudioInspectionError(underlying: error)
        }
    }
}
