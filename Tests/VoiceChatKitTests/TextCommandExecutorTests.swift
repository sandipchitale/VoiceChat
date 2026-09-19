import Foundation
import Testing
@testable import VoiceChatKit

// Spec R-STT-18 — the execute half. Each parsed `EditCommand` is applied to the
// AppKit-free `InMemoryTextDocument` and its effect on the text, the selection,
// the clipboard and the recorded side effects is asserted. `TextUnits` boundary
// behaviour has its own coverage; here the concern is that every command group
// reaches the right document primitive with the right range.

@Suite("Command-mode execution — §8.5 groups 3-6")
struct TextCommandExecutorTests {

    @discardableResult
    private func apply(_ command: EditCommand, to doc: InMemoryTextDocument) -> TextCommandOutcome {
        TextCommandExecutor.apply(command, to: doc)
    }

    // MARK: Selection

    @Test("select all covers the whole document")
    func selectAll() {
        let doc = InMemoryTextDocument("Hello world.")
        #expect(apply(.select(.all), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 0, length: 12))
    }

    @Test("select that with no selection expands to the word at the caret")
    func selectThatExpandsToWord() {
        let doc = InMemoryTextDocument("Hello world", selection: NSRange(location: 0, length: 0))
        #expect(apply(.select(.selection), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 0, length: 5))
    }

    @Test("select a phrase finds it")
    func selectPhrase() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.select(.phrase("world")), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 6, length: 5))
    }

    @Test("select a phrase that is absent reports it")
    func selectMissingPhrase() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.select(.phrase("absent")), to: doc) == .phraseNotFound("absent"))
    }

    @Test("extend selection grows to the next word")
    func extendSelection() {
        let doc = InMemoryTextDocument("one two three", selection: NSRange(location: 0, length: 3))
        #expect(apply(.extendSelection(.word, .next, count: 1), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 0, length: 7))   // "one two"
    }

    @Test("deselect collapses to the caret")
    func deselect() {
        let doc = InMemoryTextDocument("Hello", selection: NSRange(location: 0, length: 5))
        #expect(apply(.deselect, to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 0, length: 0))
    }

    // MARK: Navigation

    @Test("move to the ends of the document")
    func moveToEnds() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.moveCaret(.documentEnd), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 11, length: 0))
        #expect(apply(.moveCaret(.documentStart), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test("move after and before a phrase")
    func moveNearPhrase() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.moveAfter("Hello"), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 5, length: 0))
        #expect(apply(.moveBefore("world"), to: doc) == .ok)
        #expect(doc.selectedRange == NSRange(location: 6, length: 0))
        #expect(apply(.moveAfter("absent"), to: doc) == .phraseNotFound("absent"))
    }

    @Test("scroll reaches the surface")
    func scroll() {
        let doc = InMemoryTextDocument("Hello")
        #expect(apply(.scroll(.toTop), to: doc) == .ok)
        #expect(doc.lastScroll == .toTop)
    }

    // MARK: Editing

    @Test("replace swaps a phrase and leaves the caret after it")
    func replace() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.replace("world", with: "planet"), to: doc) == .ok)
        #expect(doc.text == "Hello planet")
        #expect(doc.selectedRange == NSRange(location: 12, length: 0))
    }

    @Test("replace a missing phrase reports it")
    func replaceMissing() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.replace("xyz", with: "abc"), to: doc) == .phraseNotFound("xyz"))
        #expect(doc.text == "Hello world")
    }

    @Test("insert before an anchor adds a joining space")
    func insertBefore() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.insert("dear", .before, near: "world"), to: doc) == .ok)
        #expect(doc.text == "Hello dear world")
    }

    @Test("correct selects the range and opens the panel")
    func correct() {
        let doc = InMemoryTextDocument("teh cat", selection: NSRange(location: 0, length: 3))
        #expect(apply(.correct(.selection), to: doc) == .ok)
        #expect(doc.correctionPanelRange == NSRange(location: 0, length: 3))
    }

    @Test("cut and copy move the selection to the clipboard")
    func cutCopyPaste() {
        let doc = InMemoryTextDocument("Hello world", selection: NSRange(location: 0, length: 5))
        #expect(apply(.cut, to: doc) == .ok)
        #expect(doc.text == " world")
        #expect(doc.selectedRange == NSRange(location: 0, length: 0))

        let doc2 = InMemoryTextDocument("ab", selection: NSRange(location: 0, length: 2))
        #expect(apply(.copy, to: doc2) == .ok)
        #expect(apply(.paste, to: doc2) == .ok)
        #expect(doc2.text == "abab")
    }

    @Test("cut with nothing selected is reported")
    func cutNothing() {
        let doc = InMemoryTextDocument("Hello", selection: NSRange(location: 0, length: 0))
        #expect(apply(.cut, to: doc) == .nothingSelected)
    }

    @Test("case transforms apply to the selection")
    func setCase() {
        let doc = InMemoryTextDocument("hello", selection: NSRange(location: 0, length: 5))
        #expect(apply(.setCase(.upper, .selection), to: doc) == .ok)
        #expect(doc.text == "HELLO")
    }

    @Test("formatting reaches the surface with the right range")
    func setFormatting() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.setFormatting(.bold, .phrase("world")), to: doc) == .ok)
        #expect(doc.appliedFormatting.count == 1)
        #expect(doc.appliedFormatting[0].0 == .bold)
        #expect(doc.appliedFormatting[0].1 == NSRange(location: 6, length: 5))
    }

    @Test("undo then redo round-trips an edit")
    func undoRedo() {
        let doc = InMemoryTextDocument("hello", selection: NSRange(location: 0, length: 5))
        apply(.setCase(.upper, .selection), to: doc)
        #expect(doc.text == "HELLO")
        #expect(apply(.undo, to: doc) == .ok)
        #expect(doc.text == "hello")
        #expect(apply(.redo, to: doc) == .ok)
        #expect(doc.text == "HELLO")
    }

    // MARK: Deletion

    @Test("delete that requires a selection")
    func deleteThat() {
        let selected = InMemoryTextDocument("Hello world", selection: NSRange(location: 0, length: 6))
        #expect(apply(.delete(.selection), to: selected) == .ok)
        #expect(selected.text == "world")

        let empty = InMemoryTextDocument("Hello", selection: NSRange(location: 0, length: 0))
        #expect(apply(.delete(.selection), to: empty) == .nothingSelected)
        #expect(empty.text == "Hello")
    }

    @Test("delete all empties the document")
    func deleteAll() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.delete(.all), to: doc) == .ok)
        #expect(doc.text == "")
    }

    @Test("delete a phrase removes exactly it")
    func deletePhrase() {
        let doc = InMemoryTextDocument("Hello world")
        #expect(apply(.delete(.phrase("world")), to: doc) == .ok)
        #expect(doc.text == "Hello ")
    }
}
