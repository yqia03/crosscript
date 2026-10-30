import Foundation
import SwiftUI
import WorkbenchCore

/// Keep the active native editor mounted while typing changes paragraph boundaries.
/// Every keystroke still saves the shared document; finishing only refreshes its displayed rows.
@MainActor final class ParagraphEditSession: ObservableObject {
    @Published private(set) var original: TranscriptParagraph?
    @Published private(set) var text = ""
    private(set) var rows: [TranscriptParagraph] = []

    func begin(_ paragraph: TranscriptParagraph, rows: [TranscriptParagraph]) {
        self.rows = rows
        text = paragraph.text
        original = paragraph
    }

    func finish() { original = nil; rows = []; text = "" }

    func currentRange(for paragraph: TranscriptParagraph) -> NSRange {
        guard let original else { return paragraph.range }
        if paragraph.id == original.id { return NSRange(location: original.range.location, length: text.utf16.count) }
        let delta = text.utf16.count - original.range.length
        return NSRange(location: paragraph.range.location + (paragraph.range.location > original.range.location ? delta : 0), length: paragraph.range.length)
    }

    func replace(_ range: NSRange, with replacement: String, processing: PostRecordingSession,
                 recordingID: UUID, resultID: UUID) -> Bool {
        guard let original else { return false }
        let old = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= old.length,
              range.length <= old.length - range.location else { return false }
        let expected = old.replacingCharacters(in: range, with: replacement)
        let paragraphRange = currentRange(for: original)
        _ = processing.replaceTranscriptParagraph(recordingID: recordingID, resultID: resultID,
            paragraphRange: paragraphRange, expectedText: text, range: range, replacement: replacement)
        // A failed disk save retains the in-memory draft, as in the full-text editor.
        guard let current = processing.transcriptText(recordingID: recordingID, resultID: resultID) as NSString?,
              paragraphRange.location <= current.length,
              expected.utf16.count <= current.length - paragraphRange.location,
              current.substring(with: NSRange(location: paragraphRange.location, length: expected.utf16.count)) == expected else { return false }
        text = expected
        return true
    }
}
