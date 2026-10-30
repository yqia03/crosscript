import Foundation
import WorkbenchCore

/// A suggested Save-panel basename; never changes the stored material name.
enum ExportFilename {
    static func pdf(_ originalName: String, direction: TextTranslationDirection, kind: PDFOutputKind) -> String {
        let basename = originalName.lowercased().hasSuffix(".pdf") ? String(originalName.dropLast(4)) : originalName
        let languages = kind == .dual || kind == .dualNoWatermark
            ? direction.sourceLanguage.exportCode + "_" + direction.targetLanguage.exportCode
            : direction.targetLanguage.exportCode
        return suggested(basename + "-" + languages, extension: "pdf")
    }

    static func record(bilingual: Bool, extension fileExtension: String, at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> String {
        suggested((bilingual ? "record-billingual-" : "record-") + timestamp(date, timeZone: timeZone), extension: fileExtension)
    }

    static func transcript(extension fileExtension: String, at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> String {
        suggested("transcrips-" + timestamp(date, timeZone: timeZone), extension: fileExtension)
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: date)
    }

    static func suggested(_ name: String, extension fileExtension: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Save panels map ':' to the legacy Mac separator. C0/DEL controls
        // are unsafe text-field input; preserve all other Unicode, including
        // combining marks and emoji joiners, instead of stripping format chars.
        let sanitized = String(String.UnicodeScalarView(trimmed.unicodeScalars.map { scalar -> UnicodeScalar in
            scalar == "/" || scalar == ":" || scalar.value < 0x20 || scalar.value == 0x7f ? "-" : scalar
        }))
        let basename = sanitized.isEmpty || sanitized == "." || sanitized == ".." ? "export" : sanitized
        return basename + "." + fileExtension
    }
}
