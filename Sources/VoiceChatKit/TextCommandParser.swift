import Foundation

// Spec §8.5, groups 3-6 — parses a normalised command-mode utterance into an
// `EditCommand`. Pure string matching; no document is needed to parse, only
// to execute (`TextCommandExecutor`).
//
// Search-target phrases (the thing being looked for) are taken from the
// already-normalised, lower-cased text: search is case- and
// diacritic-insensitive (R-STT-13), so case does not matter there.
// Inserted-content phrases (`Replace … with …`'s replacement, `Insert …`'s
// inserted text) are re-extracted from the original utterance so dictated
// case is preserved.

public enum TextCommandParser {

    public static func parse(_ normalized: String, original: String) -> EditCommand? {
        let tokens = normalized.split(separator: " ").map(String.init)
        guard let head = tokens.first else { return nil }
        let rest = Array(tokens.dropFirst())

        switch head {
        case "select":   return parseSelect(rest, normalized: normalized)
        case "extend":   return parseExtend(rest)
        case "deselect": return rest == ["that"] ? .deselect : nil
        case "move":     return parseMove(rest, normalized: normalized)
        case "scroll":   return parseScroll(rest)
        case "replace":  return parseReplace(original)
        case "insert":   return parseInsert(original)
        case "correct":  return parseTargeted(rest, normalized: normalized, prefixWordCount: 1) { .correct($0) }
        case "undo":     return rest == ["that"] ? .undo : nil
        case "redo":     return rest == ["that"] ? .redo : nil
        case "cut":      return rest == ["that"] ? .cut : nil
        case "copy":     return rest == ["that"] ? .copy : nil
        case "paste":    return rest == ["that"] ? .paste : nil
        case "capitalise", "capitalize":
            return parseTargeted(rest, normalized: normalized, prefixWordCount: 1) { .setCase(.capitalize, $0) }
        case "lowercase":
            return parseTargeted(rest, normalized: normalized, prefixWordCount: 1) { .setCase(.lower, $0) }
        case "uppercase":
            return parseTargeted(rest, normalized: normalized, prefixWordCount: 1) { .setCase(.upper, $0) }
        case "bold":
            return parseTargeted(rest, normalized: normalized, prefixWordCount: 1) { .setFormatting(.bold, $0) }
        case "italicise", "italicize":
            return parseTargeted(rest, normalized: normalized, prefixWordCount: 1) { .setFormatting(.italic, $0) }
        case "underline":
            return parseTargeted(rest, normalized: normalized, prefixWordCount: 1) { .setFormatting(.underline, $0) }
        case "delete":   return parseDelete(rest, normalized: normalized)
        default:         return nil
        }
    }

    // MARK: Shared unit-suffix grammar: "(previous|next)? (<count>)? <unit>(s)?"

    private static let unitWords: [String: TextUnit] = [
        "character": .character, "characters": .character,
        "word": .word, "words": .word,
        "sentence": .sentence, "sentences": .sentence,
        "paragraph": .paragraph, "paragraphs": .paragraph,
        "line": .line, "lines": .line,
    ]

    private static func parseUnitSuffix(_ tokens: [String]) -> (RelativeDirection?, Int, TextUnit)? {
        var tokens = tokens
        var direction: RelativeDirection?
        if tokens.first == "previous" { direction = .previous; tokens.removeFirst() }
        else if tokens.first == "next" { direction = .next; tokens.removeFirst() }

        var count = 1
        if let first = tokens.first, let n = countToken(first) {
            count = n
            tokens.removeFirst()
        }
        guard tokens.count == 1, let unit = unitWords[tokens[0]] else { return nil }
        return (direction, count, unit)
    }

    private static func countToken(_ token: String) -> Int? {
        if let n = Int(token), n > 0 { return n }
        let cardinals = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
                        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
                        "twenty": 20, "a": 1, "an": 1]
        return cardinals[token]
    }

    /// A command whose target is `that` (selection), a `<phrase>`, or is
    /// omitted entirely — "Correct that" / "Correct <phrase>", etc.
    /// `prefixWordCount` is always 1 here (the verb) since these commands
    /// have no unit form of their own.
    private static func parseTargeted(_ rest: [String], normalized: String, prefixWordCount: Int,
                                      _ build: (CommandTarget) -> EditCommand) -> EditCommand? {
        guard !rest.isEmpty else { return nil }
        if rest == ["that"] { return build(.selection) }
        let words = normalized.split(separator: " ").map(String.init)
        let phrase = words.dropFirst(prefixWordCount).joined(separator: " ")
        guard !phrase.isEmpty else { return nil }
        return build(.phrase(phrase))
    }

    // MARK: Selection (group 3)

    private static func parseSelect(_ rest: [String], normalized: String) -> EditCommand? {
        guard !rest.isEmpty else { return nil }
        if rest == ["that"] { return .select(.selection) }
        if rest == ["all"] { return .select(.all) }
        if rest == ["previous"] { return .select(.unit(.word, .previous, count: 1)) }
        if rest == ["next"] { return .select(.unit(.word, .next, count: 1)) }
        if let (direction, count, unit) = parseUnitSuffix(rest) {
            return .select(.unit(unit, direction, count: count))
        }
        // Fallback: "Select <phrase>" — the greedy remainder.
        let phrase = normalized.split(separator: " ").dropFirst().joined(separator: " ")
        guard !phrase.isEmpty else { return nil }
        return .select(.phrase(phrase))
    }

    private static func parseExtend(_ rest: [String]) -> EditCommand? {
        // "extend selection [back] <count>? <unit>"
        guard rest.first == "selection" else { return nil }
        var tail = Array(rest.dropFirst())
        var backward = false
        if tail.first == "back" { backward = true; tail.removeFirst() }
        var count = 1
        if let first = tail.first, let n = countToken(first) { count = n; tail.removeFirst() }
        guard tail.count == 1, let unit = unitWords[tail[0]] else { return nil }
        return .extendSelection(unit, backward ? .previous : .next, count: count)
    }

    // MARK: Navigation (group 4)

    private static func parseMove(_ rest: [String], normalized: String) -> EditCommand? {
        guard !rest.isEmpty else { return nil }
        switch rest {
        case ["down"]:  return .moveBy(.line, .next, count: 1)
        case ["up"]:    return .moveBy(.line, .previous, count: 1)
        case ["left"]:  return .moveBy(.character, .previous, count: 1)
        case ["right"]: return .moveBy(.character, .next, count: 1)
        default: break
        }

        if rest.first == "to" {
            let tail = Array(rest.dropFirst())
            if tail == ["beginning"] { return .moveCaret(.documentStart) }
            if tail == ["end"] { return .moveCaret(.documentEnd) }
            if tail.count == 3, tail[0] == "beginning", tail[1] == "of" {
                return anchor(for: tail[2]).map { .moveCaret($0.0 ? .unitStart($0.1!) : .selectionStart) }
            }
            if tail.count == 3, tail[0] == "end", tail[1] == "of" {
                return anchor(for: tail[2]).map { .moveCaret($0.0 ? .unitEnd($0.1!) : .selectionEnd) }
            }
            return nil
        }

        if rest.first == "after" || rest.first == "before" {
            let phrase = normalized.split(separator: " ").dropFirst(2).joined(separator: " ")
            guard !phrase.isEmpty else { return nil }
            return rest.first == "after" ? .moveAfter(phrase) : .moveBefore(phrase)
        }

        // "forward|back|right|left <count>? <unit>"
        var tail = rest
        let forward: Bool
        switch tail.first {
        case "forward", "right": forward = true
        case "back", "left": forward = false
        default: return nil
        }
        tail.removeFirst()
        var count = 1
        if let first = tail.first, let n = countToken(first) { count = n; tail.removeFirst() }
        guard tail.count == 1, let unit = unitWords[tail[0]] else { return nil }
        return .moveBy(unit, forward ? .next : .previous, count: count)
    }

    /// Returns `(true, unit)` for a text-unit target, or `(false, nil)` for
    /// "selection", which is not a `TextUnit`.
    private static func anchor(for word: String) -> (Bool, TextUnit?)? {
        if word == "selection" { return (false, nil) }
        guard let unit = unitWords[word] else { return nil }
        return (true, unit)
    }

    private static func parseScroll(_ rest: [String]) -> EditCommand? {
        switch rest {
        case ["up"]: return .scroll(.up)
        case ["down"]: return .scroll(.down)
        case ["to", "top"]: return .scroll(.toTop)
        case ["to", "bottom"]: return .scroll(.toBottom)
        default: return nil
        }
    }

    // MARK: Editing (group 5)

    /// Splits `text` on the *last* standalone occurrence of `keyword`,
    /// preserving original case on both sides (R-STT-13's rule for
    /// `Replace … with …`, applied identically to `Insert … after/before …`).
    private static func splitOnLastKeyword(_ text: String, _ keyword: String) -> (String, String)? {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let words = collapsed.split(separator: " ").map(String.init)
        guard let idx = words.lastIndex(where: { $0.lowercased() == keyword }), idx > 0, idx < words.count - 1
        else { return nil }
        return (words[..<idx].joined(separator: " "), words[(idx + 1)...].joined(separator: " "))
    }

    private static func parseReplace(_ original: String) -> EditCommand? {
        // "replace" is the first word; drop it before splitting on "with".
        guard let afterVerb = dropFirstWord(original) else { return nil }
        guard let (target, replacement) = splitOnLastKeyword(afterVerb, "with") else { return nil }
        return .replace(target, with: replacement)
    }

    private static func parseInsert(_ original: String) -> EditCommand? {
        guard let afterVerb = dropFirstWord(original) else { return nil }
        if let (phrase, anchor) = splitOnLastKeyword(afterVerb, "after") {
            return .insert(phrase, .after, near: anchor)
        }
        if let (phrase, anchor) = splitOnLastKeyword(afterVerb, "before") {
            return .insert(phrase, .before, near: anchor)
        }
        return nil
    }

    private static func dropFirstWord(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        return String(trimmed[trimmed.index(after: spaceIndex)...])
    }

    // MARK: Deletion (group 6)

    private static func parseDelete(_ rest: [String], normalized: String) -> EditCommand? {
        guard !rest.isEmpty else { return nil }
        if rest == ["that"] { return .delete(.selection) }
        if rest == ["all"] { return .delete(.all) }
        if let (direction, count, unit) = parseUnitSuffix(rest) {
            return .delete(.unit(unit, direction, count: count))
        }
        let phrase = normalized.split(separator: " ").dropFirst().joined(separator: " ")
        guard !phrase.isEmpty else { return nil }
        return .delete(.phrase(phrase))
    }
}
