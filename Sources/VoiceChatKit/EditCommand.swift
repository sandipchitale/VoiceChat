import Foundation

// Spec §8.5, groups 3-6 of R-STT-14 — every phrase in the Text Selection,
// Text Navigation, Text Editing and Text Deletion sections of
// `Commands and Dictation.md`, reduced to a small closed grammar.

public enum EditCommand: Equatable, Sendable {
    // Text Selection
    case select(CommandTarget)
    case extendSelection(TextUnit, RelativeDirection, count: Int)
    case deselect

    // Text Navigation
    case moveCaret(CaretAnchor)
    case moveBy(TextUnit, RelativeDirection, count: Int)
    case moveAfter(String)
    case moveBefore(String)
    case scroll(ScrollTarget)

    // Text Editing
    case replace(String, with: String)
    case insert(String, InsertRelation, near: String)
    case correct(CommandTarget)
    case undo
    case redo
    case cut
    case copy
    case paste
    case setCase(CaseTransform, CommandTarget)
    case setFormatting(FormattingTrait, CommandTarget)

    // Text Deletion
    case delete(CommandTarget)
}

extension EditCommand {
    /// Whether the command changes the document's text or clipboard-consuming
    /// state. Selection, navigation, scrolling and `copy` only read the
    /// document, so they are valid even on a read-only pane; the mutating
    /// commands require an editable pane.
    public var isMutating: Bool {
        switch self {
        case .select, .extendSelection, .deselect,
             .moveCaret, .moveBy, .moveAfter, .moveBefore, .scroll, .copy:
            return false
        case .replace, .insert, .correct, .undo, .redo, .cut, .paste,
             .setCase, .setFormatting, .delete:
            return true
        }
    }
}
