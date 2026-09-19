import AppKit
import Foundation

// Spec §9.2 — derive what is spoken from what is on screen.
//
// Every segment carries the document range it came from, including the ones
// that are announced but not read, so the highlight of R-UI-8 cannot drift out
// of alignment part-way through a long response (R-TTS-7).

public struct SpeechSegment: Sendable, Equatable {
    /// What the synthesiser says. Empty means "highlight this, say nothing".
    public let text: String
    /// Where in the document this came from, for highlighting.
    public let range: NSRange
    /// A beat after this segment, used to give headings and list items air.
    public let postDelay: TimeInterval

    public init(text: String, range: NSRange, postDelay: TimeInterval = 0) {
        self.text = text
        self.range = range
        self.postDelay = postDelay
    }

    public var isSpoken: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct SpeechBuildOptions: Sendable, Equatable {
    /// §11 — "Speak inline code", default on.
    public var speakInlineCode = true
    /// §11 — "Speak code blocks", default off: reading punctuation and
    /// indentation aloud is unbearable.
    public var speakCodeBlocks = false
    /// R-TTS-8.
    public var maximumCharacters = 20_000

    public init() {}
}

public enum SpeechTextBuilder {

    public static func segments(from attributed: NSAttributedString,
                                options: SpeechBuildOptions = SpeechBuildOptions()) -> [SpeechSegment] {
        guard attributed.length > 0 else { return [] }

        var blocks: [(kind: VCBlockKind, range: NSRange)] = []
        attributed.enumerateAttribute(.vcBlockKind,
                                      in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let kind = (value as? String).flatMap(VCBlockKind.init(rawValue:)) ?? .body
            // Merge neighbouring runs of the same kind so a paragraph split by
            // a bold word is still one spoken unit.
            if let last = blocks.last, last.kind == kind,
               NSMaxRange(last.range) == range.location {
                blocks[blocks.count - 1].range = NSUnionRange(last.range, range)
            } else {
                blocks.append((kind, range))
            }
        }

        let string = attributed.string as NSString
        var segments: [SpeechSegment] = []
        var spokenCharacters = 0
        var truncated = false

        for block in blocks {
            if truncated { break }
            let raw = string.substring(with: block.range)

            switch block.kind {
            case .codeBlock where !options.speakCodeBlocks:
                let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).count
                segments.append(SpeechSegment(
                    text: "Code block, \(lines) line\(lines == 1 ? "" : "s").",
                    range: block.range,
                    postDelay: 0.3))
                continue

            case .inlineCode where !options.speakInlineCode:
                segments.append(SpeechSegment(text: "", range: block.range))
                continue

            default:
                break
            }

            let prefix: String
            let postDelay: TimeInterval
            switch block.kind {
            case .heading:    prefix = "";        postDelay = 0.4
            case .listItem:   prefix = "";        postDelay = 0.2
            case .blockQuote: prefix = "Quote: "; postDelay = 0.3
            default:          prefix = "";        postDelay = 0
            }

            for (offset, sentence) in sentences(in: raw).enumerated() {
                guard !truncated else { break }
                let sentenceRange = NSRange(location: block.range.location + sentence.offset,
                                            length: sentence.length)
                var text = sentence.text
                if offset == 0 { text = prefix + text }

                if spokenCharacters + text.count > options.maximumCharacters {
                    truncated = true
                    segments.append(SpeechSegment(text: "Response truncated for reading.",
                                                  range: sentenceRange))
                    break
                }
                spokenCharacters += text.count
                segments.append(SpeechSegment(text: text,
                                              range: sentenceRange,
                                              postDelay: postDelay))
            }
        }

        return segments.filter { $0.isSpoken || $0.range.length > 0 }
    }

    // MARK: Sentence splitting

    struct Sentence { let text: String; let offset: Int; let length: Int }

    /// R-TTS-2 — sentence-level utterances, so Stop is immediate and the
    /// highlight tracks what is actually being said.
    static func sentences(in text: String) -> [Sentence] {
        var result: [Sentence] = []
        let ns = text as NSString
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .localized]) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let nsRange = NSRange(range, in: text)
            result.append(Sentence(text: trimmed, offset: nsRange.location, length: nsRange.length))
        }
        if result.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(Sentence(text: trimmed, offset: 0, length: ns.length))
            }
        }
        return result
    }
}
