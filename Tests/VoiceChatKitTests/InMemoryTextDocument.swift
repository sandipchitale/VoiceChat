import Foundation
@testable import VoiceChatKit

// An AppKit-free `TextDocument` double (R-ARCH-5 / R-STT-18). It backs the
// "one test per phrase" requirement for `TextCommandExecutor`: everything the
// executor needs — a mutable string, a selection, a clipboard, an undo stack —
// is modelled here with no NSTextView and no window. `NSTextViewDocument`
// (VoiceChatUI) is the live counterpart driven against a real text view.
final class InMemoryTextDocument: TextDocument {

    private var storage: NSMutableString
    var selectedRange: NSRange

    // Observable side effects, recorded so tests can assert them.
    private(set) var clipboard: String = ""
    private(set) var appliedFormatting: [(FormattingTrait, NSRange)] = []
    private(set) var correctionPanelRange: NSRange?
    private(set) var lastScroll: ScrollTarget?

    private var undoStack: [(String, NSRange)] = []
    private var redoStack: [(String, NSRange)] = []

    init(_ text: String, selection: NSRange? = nil) {
        storage = NSMutableString(string: text)
        selectedRange = selection ?? NSRange(location: 0, length: 0)
    }

    var text: String { storage as String }

    private func snapshot() {
        undoStack.append((storage as String, selectedRange))
        redoStack.removeAll()
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        snapshot()
        storage.replaceCharacters(in: range, with: string)
    }

    func setFormatting(_ trait: FormattingTrait, on range: NSRange) {
        appliedFormatting.append((trait, range))
    }

    func setCase(_ transform: CaseTransform, on range: NSRange) {
        snapshot()
        let original = storage.substring(with: range)
        let transformed: String
        switch transform {
        case .capitalize: transformed = original.capitalized
        case .lower:      transformed = original.lowercased()
        case .upper:      transformed = original.uppercased()
        }
        storage.replaceCharacters(in: range, with: transformed)
    }

    func showCorrectionPanel(for range: NSRange) {
        correctionPanelRange = range
    }

    func cut(_ range: NSRange) {
        clipboard = storage.substring(with: range)
        replaceCharacters(in: range, with: "")
        selectedRange = NSRange(location: range.location, length: 0)
    }

    func copy(_ range: NSRange) {
        clipboard = storage.substring(with: range)
    }

    func pasteAtCaret() {
        replaceCharacters(in: NSRange(location: selectedRange.location, length: 0), with: clipboard)
        selectedRange = NSRange(location: selectedRange.location + (clipboard as NSString).length, length: 0)
    }

    func performUndo() {
        guard let (text, selection) = undoStack.popLast() else { return }
        redoStack.append((storage as String, selectedRange))
        storage = NSMutableString(string: text)
        selectedRange = selection
    }

    func performRedo() {
        guard let (text, selection) = redoStack.popLast() else { return }
        undoStack.append((storage as String, selectedRange))
        storage = NSMutableString(string: text)
        selectedRange = selection
    }

    func scroll(_ target: ScrollTarget) {
        lastScroll = target
    }
}
