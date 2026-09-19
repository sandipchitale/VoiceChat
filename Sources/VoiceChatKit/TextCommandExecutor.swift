import Foundation

// Spec §8.5 — applies a parsed `EditCommand` to a `TextDocument`. Every branch
// here is exercised against the in-memory test double with no AppKit
// (R-ARCH-5); `NSTextViewDocument` (VoiceChatUI) supplies the same protocol
// against a live window.

public enum TextCommandExecutor {

    public static func apply(_ command: EditCommand, to document: TextDocument) -> TextCommandOutcome {
        switch command {
        case .select(let target):
            return select(target, in: document)
        case .extendSelection(let unit, let direction, let count):
            return extend(unit, direction, count, in: document)
        case .deselect:
            document.selectedRange = NSRange(location: document.selectedRange.location, length: 0)
            return .ok
        case .moveCaret(let anchor):
            return moveCaret(anchor, in: document)
        case .moveBy(let unit, let direction, let count):
            return moveBy(unit, direction, count, in: document)
        case .moveAfter(let phrase):
            return moveNear(phrase, after: true, in: document)
        case .moveBefore(let phrase):
            return moveNear(phrase, after: false, in: document)
        case .scroll(let target):
            document.scroll(target)
            return .ok
        case .replace(let phrase, let replacement):
            return replace(phrase, with: replacement, in: document)
        case .insert(let phrase, let relation, let anchor):
            return insert(phrase, relation, near: anchor, in: document)
        case .correct(let target):
            return correct(target, in: document)
        case .undo:
            document.performUndo()
            return .ok
        case .redo:
            document.performRedo()
            return .ok
        case .cut:
            return cutOrCopy(cutting: true, in: document)
        case .copy:
            return cutOrCopy(cutting: false, in: document)
        case .paste:
            document.pasteAtCaret()
            return .ok
        case .setCase(let transform, let target):
            switch resolveRange(target, in: document) {
            case .success(let range): document.setCase(transform, on: range); return .ok
            case .failure(let outcome): return outcome
            }
        case .setFormatting(let trait, let target):
            switch resolveRange(target, in: document) {
            case .success(let range): document.setFormatting(trait, on: range); return .ok
            case .failure(let outcome): return outcome
            }
        case .delete(let target):
            return delete(target, in: document)
        }
    }

    // MARK: Target resolution

    /// `.selection` here is strict: acting on "that" with nothing selected is
    /// reported rather than guessed at, because the actions that reach this
    /// path (delete, cut, bold, correct, case) mutate or expose the clipboard.
    /// `select()` below has its own, more permissive, resolution for the
    /// "Select that" command itself.
    private static func resolveRange(_ target: CommandTarget, in document: TextDocument) -> Result<NSRange, TextCommandOutcome> {
        switch target {
        case .selection:
            let sel = document.selectedRange
            return sel.length > 0 ? .success(sel) : .failure(.nothingSelected)
        case .all:
            return .success(NSRange(location: 0, length: document.length))
        case .unit(let unit, let direction, let count):
            guard let range = TextUnits.range(of: unit, direction: direction, count: count,
                                              in: document.text, from: document.selectedRange.location)
            else { return .failure(.notApplicable("Nothing there")) }
            return .success(range)
        case .phrase(let phrase):
            guard let range = TextUnits.phraseRange(phrase, in: document.text, near: document.selectedRange.location)
            else { return .failure(.phraseNotFound(phrase)) }
            return .success(range)
        }
    }

    // MARK: Selection (group 3)

    private static func select(_ target: CommandTarget, in document: TextDocument) -> TextCommandOutcome {
        // "Select that" with an empty selection falls back to the word at the
        // caret — a safe expansion, unlike acting on an implied selection.
        if case .selection = target {
            let sel = document.selectedRange
            if sel.length > 0 { return .ok }
            guard let word = TextUnits.range(of: .word, direction: nil, count: 1,
                                             in: document.text, from: sel.location)
            else { return .notApplicable("Nothing to select") }
            document.selectedRange = word
            return .ok
        }
        switch resolveRange(target, in: document) {
        case .success(let range): document.selectedRange = range; return .ok
        case .failure(let outcome): return outcome
        }
    }

    private static func extend(_ unit: TextUnit, _ direction: RelativeDirection, _ count: Int,
                               in document: TextDocument) -> TextCommandOutcome {
        let sel = document.selectedRange
        switch direction {
        case .next:
            guard let addition = TextUnits.range(of: unit, direction: .next, count: count,
                                                 in: document.text, from: sel.location + sel.length)
            else { return .notApplicable("Nothing to extend") }
            let newEnd = addition.location + addition.length
            document.selectedRange = document.clamped(NSRange(location: sel.location, length: newEnd - sel.location))
        case .previous:
            guard let addition = TextUnits.range(of: unit, direction: .previous, count: count,
                                                 in: document.text, from: sel.location)
            else { return .notApplicable("Nothing to extend") }
            let end = sel.location + sel.length
            document.selectedRange = document.clamped(NSRange(location: addition.location, length: end - addition.location))
        }
        return .ok
    }

    // MARK: Navigation (group 4)

    private static func moveCaret(_ anchor: CaretAnchor, in document: TextDocument) -> TextCommandOutcome {
        switch anchor {
        case .documentStart:
            document.selectedRange = NSRange(location: 0, length: 0)
        case .documentEnd:
            document.selectedRange = NSRange(location: document.length, length: 0)
        case .unitStart(let unit):
            guard let r = TextUnits.range(of: unit, direction: nil, count: 1,
                                          in: document.text, from: document.selectedRange.location)
            else { return .notApplicable("Nothing there") }
            document.selectedRange = NSRange(location: r.location, length: 0)
        case .unitEnd(let unit):
            guard let r = TextUnits.range(of: unit, direction: nil, count: 1,
                                          in: document.text, from: document.selectedRange.location)
            else { return .notApplicable("Nothing there") }
            document.selectedRange = NSRange(location: r.location + r.length, length: 0)
        case .selectionStart:
            document.selectedRange = NSRange(location: document.selectedRange.location, length: 0)
        case .selectionEnd:
            let sel = document.selectedRange
            document.selectedRange = NSRange(location: sel.location + sel.length, length: 0)
        }
        return .ok
    }

    private static func moveBy(_ unit: TextUnit, _ direction: RelativeDirection, _ count: Int,
                               in document: TextDocument) -> TextCommandOutcome {
        let location = document.selectedRange.location
        switch direction {
        case .next:
            guard let r = TextUnits.range(of: unit, direction: .next, count: count, in: document.text, from: location)
            else { return .notApplicable("Already at the end") }
            document.selectedRange = NSRange(location: r.location + r.length, length: 0)
        case .previous:
            guard let r = TextUnits.range(of: unit, direction: .previous, count: count, in: document.text, from: location)
            else { return .notApplicable("Already at the start") }
            document.selectedRange = NSRange(location: r.location, length: 0)
        }
        return .ok
    }

    private static func moveNear(_ phrase: String, after: Bool, in document: TextDocument) -> TextCommandOutcome {
        guard let range = TextUnits.phraseRange(phrase, in: document.text, near: document.selectedRange.location)
        else { return .phraseNotFound(phrase) }
        let location = after ? range.location + range.length : range.location
        document.selectedRange = NSRange(location: location, length: 0)
        return .ok
    }

    // MARK: Editing (group 5)

    private static func replace(_ phrase: String, with replacement: String, in document: TextDocument) -> TextCommandOutcome {
        guard let range = TextUnits.phraseRange(phrase, in: document.text, near: document.selectedRange.location)
        else { return .phraseNotFound(phrase) }
        document.replaceCharacters(in: range, with: replacement)
        document.selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        return .ok
    }

    private static func insert(_ phrase: String, _ relation: InsertRelation, near anchor: String,
                               in document: TextDocument) -> TextCommandOutcome {
        guard let anchorRange = TextUnits.phraseRange(anchor, in: document.text, near: document.selectedRange.location)
        else { return .phraseNotFound(anchor) }
        let insertionPoint = relation == .after ? anchorRange.location + anchorRange.length : anchorRange.location
        let leading = insertionPoint > 0 && !isWhitespace(document.text, at: insertionPoint - 1)
        let trailing = insertionPoint < document.length && !isWhitespace(document.text, at: insertionPoint)
        let text = (leading ? " " : "") + phrase + (trailing ? " " : "")
        document.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: text)
        document.selectedRange = NSRange(location: insertionPoint + (text as NSString).length, length: 0)
        return .ok
    }

    private static func isWhitespace(_ text: String, at utf16Offset: Int) -> Bool {
        let ns = text as NSString
        guard utf16Offset >= 0, utf16Offset < ns.length else { return true }
        return ns.substring(with: NSRange(location: utf16Offset, length: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func correct(_ target: CommandTarget, in document: TextDocument) -> TextCommandOutcome {
        switch resolveRange(target, in: document) {
        case .success(let range):
            document.selectedRange = range
            document.showCorrectionPanel(for: range)
            return .ok
        case .failure(let outcome): return outcome
        }
    }

    private static func cutOrCopy(cutting: Bool, in document: TextDocument) -> TextCommandOutcome {
        let sel = document.selectedRange
        guard sel.length > 0 else { return .nothingSelected }
        if cutting { document.cut(sel) } else { document.copy(sel) }
        return .ok
    }

    // MARK: Deletion (group 6)

    private static func delete(_ target: CommandTarget, in document: TextDocument) -> TextCommandOutcome {
        switch resolveRange(target, in: document) {
        case .success(let range):
            document.replaceCharacters(in: range, with: "")
            document.selectedRange = NSRange(location: range.location, length: 0)
            return .ok
        case .failure(let outcome): return outcome
        }
    }
}
