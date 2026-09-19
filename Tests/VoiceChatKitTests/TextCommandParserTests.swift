import Testing
@testable import VoiceChatKit

// Spec R-STT-18 — every phrase in the Text Selection, Navigation, Editing and
// Deletion sections of `Commands and Dictation.md` must have an implementation
// and at least one test. This suite covers the parse half: each phrase template
// maps to the expected `EditCommand`. Utterances are normalised exactly as the
// live path does (`VoiceCommandRouter.normalise`) before parsing.

@Suite("Command-mode parsing — §8.5 groups 3-6")
struct TextCommandParserTests {

    /// Parse a spoken phrase the way the dispatcher does: normalise first, then
    /// hand both the normalised and original forms to the parser.
    private func parse(_ phrase: String) -> EditCommand? {
        TextCommandParser.parse(VoiceCommandRouter.normalise(phrase), original: phrase)
    }

    // MARK: Text Selection

    @Test("selection — that, all, phrase, previous/next word")
    func selectionBasics() {
        #expect(parse("Select that") == .select(.selection))
        #expect(parse("Select all") == .select(.all))
        #expect(parse("Select hello world") == .select(.phrase("hello world")))
        #expect(parse("Select previous") == .select(.unit(.word, .previous, count: 1)))
        #expect(parse("Select next") == .select(.unit(.word, .next, count: 1)))
    }

    @Test("selection — each unit, bare and directional")
    func selectionUnits() {
        for (word, unit) in [("character", TextUnit.character), ("word", .word),
                             ("sentence", .sentence), ("paragraph", .paragraph), ("line", .line)] {
            #expect(parse("Select \(word)") == .select(.unit(unit, nil, count: 1)))
            #expect(parse("Select previous \(word)") == .select(.unit(unit, .previous, count: 1)))
            #expect(parse("Select next \(word)") == .select(.unit(unit, .next, count: 1)))
        }
    }

    @Test("selection — counted units in both directions")
    func selectionCounted() {
        #expect(parse("Select 3 characters") == .select(.unit(.character, nil, count: 3)))
        #expect(parse("Select previous two words") == .select(.unit(.word, .previous, count: 2)))
        #expect(parse("Select next 4 sentences") == .select(.unit(.sentence, .next, count: 4)))
        #expect(parse("Select 2 paragraphs") == .select(.unit(.paragraph, nil, count: 2)))
        #expect(parse("Select next five lines") == .select(.unit(.line, .next, count: 5)))
    }

    @Test("selection — extend forward and back, and deselect")
    func extendAndDeselect() {
        #expect(parse("Extend selection 3 characters") == .extendSelection(.character, .next, count: 3))
        #expect(parse("Extend selection back 2 words") == .extendSelection(.word, .previous, count: 2))
        #expect(parse("Extend selection 1 sentence") == .extendSelection(.sentence, .next, count: 1))
        #expect(parse("Extend selection back 4 paragraphs") == .extendSelection(.paragraph, .previous, count: 4))
        #expect(parse("Extend selection 2 lines") == .extendSelection(.line, .next, count: 2))
        #expect(parse("Deselect that") == .deselect)
    }

    // MARK: Text Navigation

    @Test("navigation — arrows and scrolling")
    func arrowsAndScroll() {
        #expect(parse("Move down") == .moveBy(.line, .next, count: 1))
        #expect(parse("Move up") == .moveBy(.line, .previous, count: 1))
        #expect(parse("Move left") == .moveBy(.character, .previous, count: 1))
        #expect(parse("Move right") == .moveBy(.character, .next, count: 1))
        #expect(parse("Scroll up") == .scroll(.up))
        #expect(parse("Scroll down") == .scroll(.down))
        #expect(parse("Scroll to top") == .scroll(.toTop))
        #expect(parse("Scroll to bottom") == .scroll(.toBottom))
    }

    @Test("navigation — move to document, unit and selection anchors")
    func moveToAnchors() {
        #expect(parse("Move to beginning") == .moveCaret(.documentStart))
        #expect(parse("Move to end") == .moveCaret(.documentEnd))
        #expect(parse("Move to beginning of word") == .moveCaret(.unitStart(.word)))
        #expect(parse("Move to end of word") == .moveCaret(.unitEnd(.word)))
        #expect(parse("Move to beginning of sentence") == .moveCaret(.unitStart(.sentence)))
        #expect(parse("Move to end of sentence") == .moveCaret(.unitEnd(.sentence)))
        #expect(parse("Move to beginning of paragraph") == .moveCaret(.unitStart(.paragraph)))
        #expect(parse("Move to end of paragraph") == .moveCaret(.unitEnd(.paragraph)))
        #expect(parse("Move to beginning of line") == .moveCaret(.unitStart(.line)))
        #expect(parse("Move to end of line") == .moveCaret(.unitEnd(.line)))
        #expect(parse("Move to beginning of selection") == .moveCaret(.selectionStart))
        #expect(parse("Move to end of selection") == .moveCaret(.selectionEnd))
    }

    @Test("navigation — counted moves, forward/back and right/left")
    func countedMoves() {
        #expect(parse("Move forward 3 characters") == .moveBy(.character, .next, count: 3))
        #expect(parse("Move back 2 words") == .moveBy(.word, .previous, count: 2))
        #expect(parse("Move forward one sentence") == .moveBy(.sentence, .next, count: 1))
        #expect(parse("Move back 4 paragraphs") == .moveBy(.paragraph, .previous, count: 4))
        #expect(parse("Move forward 2 lines") == .moveBy(.line, .next, count: 2))
        #expect(parse("Move right 5 characters") == .moveBy(.character, .next, count: 5))
        #expect(parse("Move left 3 words") == .moveBy(.word, .previous, count: 3))
        #expect(parse("Move right 2 lines") == .moveBy(.line, .next, count: 2))
    }

    @Test("navigation — move relative to a phrase")
    func moveNearPhrase() {
        #expect(parse("Move after the quick brown fox") == .moveAfter("the quick brown fox"))
        #expect(parse("Move before conclusion") == .moveBefore("conclusion"))
    }

    // MARK: Text Editing

    @Test("editing — replace and insert preserve dictated case")
    func replaceAndInsert() {
        #expect(parse("Replace Hello with Goodbye") == .replace("Hello", with: "Goodbye"))
        #expect(parse("Insert World after Hello") == .insert("World", .after, near: "Hello"))
        #expect(parse("Insert intro before Body") == .insert("intro", .before, near: "Body"))
    }

    @Test("editing — correct, undo/redo, clipboard")
    func correctUndoClipboard() {
        #expect(parse("Correct that") == .correct(.selection))
        #expect(parse("Correct teh") == .correct(.phrase("teh")))
        #expect(parse("Undo that") == .undo)
        #expect(parse("Redo that") == .redo)
        #expect(parse("Cut that") == .cut)
        #expect(parse("Copy that") == .copy)
        #expect(parse("Paste that") == .paste)
    }

    @Test("editing — case and formatting on that or a phrase")
    func caseAndFormatting() {
        #expect(parse("Capitalise that") == .setCase(.capitalize, .selection))
        #expect(parse("Capitalize heading") == .setCase(.capitalize, .phrase("heading")))
        #expect(parse("Lowercase that") == .setCase(.lower, .selection))
        #expect(parse("Lowercase Name") == .setCase(.lower, .phrase("name")))
        #expect(parse("Uppercase that") == .setCase(.upper, .selection))
        #expect(parse("Uppercase title") == .setCase(.upper, .phrase("title")))
        #expect(parse("Bold that") == .setFormatting(.bold, .selection))
        #expect(parse("Bold important") == .setFormatting(.bold, .phrase("important")))
        #expect(parse("Italicise that") == .setFormatting(.italic, .selection))
        #expect(parse("Italicize note") == .setFormatting(.italic, .phrase("note")))
        #expect(parse("Underline that") == .setFormatting(.underline, .selection))
        #expect(parse("Underline link") == .setFormatting(.underline, .phrase("link")))
    }

    // MARK: Text Deletion

    @Test("deletion — that, all and a phrase")
    func deletionBasics() {
        #expect(parse("Delete that") == .delete(.selection))
        #expect(parse("Delete all") == .delete(.all))
        #expect(parse("Delete the last sentence here") == .delete(.phrase("the last sentence here")))
    }

    @Test("deletion — each unit, directional and counted")
    func deletionUnits() {
        for (word, unit) in [("character", TextUnit.character), ("word", .word),
                             ("sentence", .sentence), ("paragraph", .paragraph), ("line", .line)] {
            #expect(parse("Delete \(word)") == .delete(.unit(unit, nil, count: 1)))
            #expect(parse("Delete previous \(word)") == .delete(.unit(unit, .previous, count: 1)))
            #expect(parse("Delete next \(word)") == .delete(.unit(unit, .next, count: 1)))
        }
        #expect(parse("Delete 3 characters") == .delete(.unit(.character, nil, count: 3)))
        #expect(parse("Delete previous two words") == .delete(.unit(.word, .previous, count: 2)))
        #expect(parse("Delete next 4 lines") == .delete(.unit(.line, .next, count: 4)))
    }

    // MARK: Non-commands

    @Test("a phrase that is not a command parses to nil")
    func nonCommand() {
        #expect(parse("what is the weather today") == nil)
        #expect(parse("") == nil)
    }
}
