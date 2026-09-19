import Foundation

// Spec §8.5 — pure text-unit algorithms shared by the real NSTextView adapter
// and the in-memory test double, so unit-boundary behaviour is defined once
// and is fully testable without AppKit (R-ARCH-5).
//
// "Line" here means the logical line delimited by "\n" (`.byLines`), not the
// visually wrapped line a real text view would show — the wrapped extent
// depends on window width, which does not exist in a headless test.

public enum TextUnit: String, Sendable, CaseIterable {
    case character, word, sentence, paragraph, line
}

public enum RelativeDirection: Sendable, Equatable {
    case previous, next
}

public enum TextUnits {

    /// R-STT-12 — `<count>` accepts digits, the cardinal words one–twenty, and
    /// "a"/"an" as 1. Absent or unparseable defaults to 1.
    public static func parseCount(_ token: String?) -> Int {
        guard let token, !token.isEmpty else { return 1 }
        if let n = Int(token), n > 0 { return n }
        return cardinals[token] ?? 1
    }

    private static let cardinals: [String: Int] = {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                     "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                     "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        var table = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
        table["a"] = 1
        table["an"] = 1
        return table
    }()

    /// The range of the unit found by walking from `location` in `direction`
    /// for `count` steps. `direction == nil` means "the unit at the caret",
    /// i.e. `count` consecutive units starting at the one containing (or
    /// immediately after) `location`.
    public static func range(of unit: TextUnit, direction: RelativeDirection?,
                             count: Int, in text: String, from location: Int) -> NSRange? {
        let count = max(1, count)
        switch unit {
        case .character:
            return characterRange(direction: direction, count: count, in: text, from: location)
        default:
            let units = boundaries(of: unit, in: text)
            return counted(units, direction: direction, count: count, from: location, textLength: (text as NSString).length)
        }
    }

    private static func characterRange(direction: RelativeDirection?, count: Int,
                                       in text: String, from location: Int) -> NSRange? {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return nil }
        let loc = min(max(location, 0), length)
        switch direction {
        case .previous:
            let start = max(0, loc - count)
            guard start < loc else { return nil }
            return NSRange(location: start, length: loc - start)
        case .next, .none:
            let end = min(length, loc + count)
            guard end > loc else { return nil }
            return NSRange(location: loc, length: end - loc)
        }
    }

    /// All unit ranges in reading order, computed once with the platform
    /// tokenizer (`enumerateSubstrings`), which is the same ICU-backed
    /// segmentation `NSTextView` itself relies on.
    static func boundaries(of unit: TextUnit, in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let options: NSString.EnumerationOptions
        switch unit {
        case .word: options = [.byWords, .substringNotRequired]
        case .sentence: options = [.bySentences, .substringNotRequired]
        case .paragraph: options = [.byParagraphs, .substringNotRequired]
        case .line: options = [.byLines, .substringNotRequired]
        case .character: return []
        }
        var ranges: [NSRange] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: options) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    private static func counted(_ units: [NSRange], direction: RelativeDirection?, count: Int,
                                from location: Int, textLength: Int) -> NSRange? {
        guard !units.isEmpty else { return nil }
        switch direction {
        case .none:
            guard let startIndex = units.firstIndex(where: { $0.location + $0.length > location }) ?? units.indices.last
            else { return nil }
            let endIndex = min(startIndex + count - 1, units.count - 1)
            return NSRange(location: units[startIndex].location,
                          length: units[endIndex].location + units[endIndex].length - units[startIndex].location)
        case .next:
            guard let startIndex = units.firstIndex(where: { $0.location >= location }) else { return nil }
            let endIndex = min(startIndex + count - 1, units.count - 1)
            return NSRange(location: units[startIndex].location,
                          length: units[endIndex].location + units[endIndex].length - units[startIndex].location)
        case .some(.previous):
            guard let endIndex = units.lastIndex(where: { $0.location < location }) else { return nil }
            let startIndex = max(0, endIndex - count + 1)
            return NSRange(location: units[startIndex].location,
                          length: units[endIndex].location + units[endIndex].length - units[startIndex].location)
        }
    }

    /// R-STT-13 — `<phrase>` resolution: case- and diacritic-insensitive,
    /// nearest occurrence to `location`, searching forward first and then
    /// wrapping to the start.
    public static func phraseRange(_ phrase: String, in text: String, near location: Int) -> NSRange? {
        guard !phrase.isEmpty else { return nil }
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return nil }
        let loc = min(max(location, 0), length)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        let forward = ns.range(of: phrase, options: options, range: NSRange(location: loc, length: length - loc))
        if forward.location != NSNotFound { return forward }

        let wrapped = ns.range(of: phrase, options: options, range: NSRange(location: 0, length: loc))
        if wrapped.location != NSNotFound { return wrapped }

        return nil
    }
}
