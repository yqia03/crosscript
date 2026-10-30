import Foundation

extension PostRecordingSession {
    /// A paragraph editor carries its current slice, so a stale view cannot edit another passage.
    @discardableResult public func replaceTranscriptParagraph(recordingID: UUID, resultID: UUID,
        paragraphRange: NSRange, expectedText: String, range: NSRange, replacement: String) -> Bool {
        guard let text = transcriptText(recordingID: recordingID, resultID: resultID) else { return false }
        let source = text as NSString
        guard paragraphRange.location >= 0, paragraphRange.length >= 0,
              paragraphRange.location <= source.length,
              paragraphRange.length <= source.length - paragraphRange.location,
              source.substring(with: paragraphRange) == expectedText,
              range.location >= 0, range.length >= 0, range.location <= paragraphRange.length,
              range.length <= paragraphRange.length - range.location else { return false }
        return replaceTranscriptText(recordingID: recordingID, resultID: resultID,
            range: NSRange(location: paragraphRange.location + range.location, length: range.length), replacement: replacement)
    }
}
