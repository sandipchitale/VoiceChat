import Foundation

// Spec §8.5 / §15.2 — the abstract surface the command dispatcher drives.
// `NSTextViewDocument` (VoiceChatUI) is the real adapter; an in-memory double
// backs the "one test per phrase" requirement (R-STT-18) with no AppKit and
// no window (R-ARCH-5).

public enum FormattingTrait: Sendable { case bold, italic, underline }
public enum CaseTransform: Sendable { case capitalize, lower, upper }

public enum CaretAnchor: Sendable, Equatable {
    case documentStart, documentEnd
    case unitStart(TextUnit), unitEnd(TextUnit)
    case selectionStart, selectionEnd
}

public enum ScrollTarget: Sendable { case up, down, toTop, toBottom }

public enum InsertRelation: Sendable { case after, before }

/// What a command that can act on "that", a counted unit run, or a `<phrase>`
/// is aimed at.
public enum CommandTarget: Sendable, Equatable {
    case selection                                          // "that"
    case all
    case unit(TextUnit, RelativeDirection?, count: Int)      // "word", "previous word", "3 words"
    case phrase(String)
}

public enum TextCommandOutcome: Sendable, Equatable, Error {
    case ok
    case phraseNotFound(String)
    case nothingSelected
    /// A command that is well-formed but has nothing to act on right now,
    /// e.g. "Move after" a phrase that isn't in the document.
    case notApplicable(String)
}

/// The primitive operations a concrete text surface must provide. Everything
/// that can be computed from `text` + `selectedRange` alone (unit boundaries,
/// phrase search, `<count>` clamping) lives in `TextCommandExecutor` instead,
/// so it is written once and shared by every conformer.
public protocol TextDocument: AnyObject {
    var text: String { get }
    var selectedRange: NSRange { get set }

    func replaceCharacters(in range: NSRange, with string: String)
    func setFormatting(_ trait: FormattingTrait, on range: NSRange)
    func setCase(_ transform: CaseTransform, on range: NSRange)
    func showCorrectionPanel(for range: NSRange)
    func cut(_ range: NSRange)
    func copy(_ range: NSRange)
    func pasteAtCaret()
    func performUndo()
    func performRedo()
    func scroll(_ target: ScrollTarget)
}

extension TextDocument {
    var length: Int { (text as NSString).length }

    /// Clamps a proposed range to the document extent — R-STT-12's "a count
    /// larger than the available extent clamps to the extent" applies to any
    /// unit, not just counted ones.
    func clamped(_ range: NSRange) -> NSRange {
        let length = self.length
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, location), length)
        return NSRange(location: location, length: end - location)
    }
}
