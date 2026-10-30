import Foundation

public struct TranscriptTextRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

/// A service-produced source interval has an identity independent of edited paragraphs.
public struct TranscriptAnchor: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceStart: TimeInterval
    public let sourceEnd: TimeInterval
    public let originalRange: TranscriptTextRange
    public let chunkStartFrame: Int64?
    public var range: TranscriptTextRange
    public var isStartReliable: Bool

    public init(id: UUID = UUID(), sourceStart: TimeInterval, sourceEnd: TimeInterval, range: TranscriptTextRange, chunkStartFrame: Int64? = nil) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        originalRange = range
        self.chunkStartFrame = chunkStartFrame
        self.range = range
        isStartReliable = true
    }
}

public struct TranscribedAudio: Sendable {
    public let text: String
    public let anchors: [TranscriptAnchor]
    public init(text: String, anchors: [TranscriptAnchor] = []) { self.text = text; self.anchors = anchors }
}

public struct TranscriptParagraph: Identifiable, Equatable {
    public let id: String
    public let text: String
    public let range: NSRange
    public let playbackStart: TimeInterval?
}

public enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case text = "txt", markdown = "md"
}

public struct TranscriptDocument: Codable, Equatable, Sendable {
    public private(set) var text: String
    public private(set) var anchors: [TranscriptAnchor]
    public private(set) var missingIntervals: [MissingInterval]

    public init(text: String, anchors: [TranscriptAnchor] = [], missingIntervals: [MissingInterval] = []) {
        self.missingIntervals = MissingInterval.normalized(missingIntervals)
        self.text = text
        let source = text as NSString
        self.anchors = anchors.filter {
            $0.sourceStart.isFinite && $0.sourceEnd.isFinite && $0.sourceStart >= 0 && $0.sourceEnd >= $0.sourceStart &&
            $0.range.length > 0 && Self.contains($0.range.nsRange, in: source)
        }
    }

    private enum CodingKeys: String, CodingKey { case text, anchors, missingIntervals }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try values.decode(String.self, forKey: .text),
            anchors: try values.decodeIfPresent([TranscriptAnchor].self, forKey: .anchors) ?? [],
            missingIntervals: try values.decodeIfPresent([MissingInterval].self, forKey: .missingIntervals) ?? [])
    }

    public var paragraphs: [TranscriptParagraph] {
        let source = text as NSString
        var paragraphs: [TranscriptParagraph] = []
        var lines: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in lines.append(range) }
        // Index source starts once; scrolling and paragraph actions must not scan every
        // anchor for every line. Keep the first source at a duplicate offset, as before.
        var firstAnchorAtStart: [Int: TranscriptAnchor] = [:]
        for anchor in anchors where anchor.isStartReliable {
            if firstAnchorAtStart[anchor.range.location] == nil {
                firstAnchorAtStart[anchor.range.location] = anchor
            }
        }
        let starts = firstAnchorAtStart.keys.sorted()
        var nextStart = 0
        for lineRange in lines {
            let lineEnd = NSMaxRange(lineRange)
            while nextStart < starts.count && starts[nextStart] <= lineRange.location { nextStart += 1 }
            var boundaries = [lineRange.location]
            while nextStart < starts.count && starts[nextStart] < lineEnd {
                boundaries.append(starts[nextStart])
                nextStart += 1
            }
            boundaries.append(lineEnd)
            for (offset, end) in zip(boundaries, boundaries.dropFirst()) {
                let range = NSRange(location: offset, length: end - offset)
                let line = source.substring(with: range)
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let start = line.prefix(while: { $0.isWhitespace }).utf16.count + offset
                let anchor = firstAnchorAtStart[start]
                paragraphs.append(TranscriptParagraph(id: "\(anchor?.id.uuidString ?? "untimed")-\(offset)", text: line, range: range, playbackStart: anchor?.sourceStart))
            }
        }
        return paragraphs
    }

    /// Timestamp labels use the same reliable source starts as paragraph playback.
    /// Only labels and, for adjacent segments, a separating line break are inserted.
    func exportText(includeTimestamps: Bool, language: AppLanguage) -> String {
        guard includeTimestamps else { return text }
        let source = text as NSString
        let output = NSMutableString(string: text)
        let displayed = paragraphs
        for index in displayed.indices.reversed() {
            let paragraph = displayed[index]
            let label = paragraph.playbackStart.flatMap(Self.exportTimestamp) ?? language.text("无时间信息", "Timing unavailable")
            var separator = ""
            if index > 0 {
                let gap = NSRange(location: NSMaxRange(displayed[index - 1].range),
                                  length: paragraph.range.location - NSMaxRange(displayed[index - 1].range))
                if source.rangeOfCharacter(from: .newlines, options: [], range: gap).location == NSNotFound {
                    separator = "\n"
                }
            }
            output.insert("\(separator)[\(label)] ", at: paragraph.range.location)
        }
        return output as String
    }

    private static func exportTimestamp(_ seconds: TimeInterval) -> String? {
        let rounded = (seconds * 1_000).rounded()
        guard rounded.isFinite, rounded >= 0, rounded < Double(Int64.max) else { return nil }
        let milliseconds = Int64(rounded)
        return String(format: "%02lld:%02lld:%02lld.%03lld", milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    @discardableResult public mutating func replace(range: NSRange, with replacement: String) -> Bool {
        guard Self.contains(range, in: text as NSString), let stringRange = Range(range, in: text) else { return false }
        let replacementLength = replacement.utf16.count
        let delta = replacementLength - range.length
        let editEnd = NSMaxRange(range)
        anchors = anchors.compactMap { original in
            var anchor = original
            let start = anchor.range.location
            let end = start + anchor.range.length
            if editEnd <= start {
                anchor.range.location += delta
            } else if range.location >= end {
                return anchor
            } else if range.location <= start && editEnd >= end {
                return nil
            } else {
                if range.location <= start {
                    anchor.isStartReliable = false
                    anchor.range.location = range.location + replacementLength
                    anchor.range.length = end - editEnd
                } else {
                    anchor.range.length = max(0, min(end, range.location) - start + replacementLength + max(0, end - editEnd))
                }
            }
            return anchor.range.length > 0 ? anchor : nil
        }
        text.replaceSubrange(stringRange, with: replacement)
        return true
    }

    /// Full-text clients supply one contiguous edit. Exact editor ranges are preferred.
    @discardableResult public mutating func replaceText(with value: String) -> Bool {
        guard text != value else { return true }
        let old = Array(text), new = Array(value)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let location = String(old.prefix(prefix)).utf16.count
        let length = String(old[prefix..<(old.count - suffix)]).utf16.count
        return replace(range: NSRange(location: location, length: length), with: String(new[prefix..<(new.count - suffix)]))
    }

    private static func contains(_ range: NSRange, in source: NSString) -> Bool {
        let length = source.length
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { return false }
        func isScalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < length else { return true }
            return !(0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        return isScalarBoundary(range.location) && isScalarBoundary(NSMaxRange(range))
    }
}
