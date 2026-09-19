import Testing
@testable import VoiceChatKit

// R-STT-18 completeness gate: every literal command phrase in
// `Commands and Dictation.md` (Text Selection / Navigation / Editing / Deletion)
// must parse to a non-nil `EditCommand`. Placeholders are substituted:
// `<phrase>` → a concrete phrase, `<count>` → "3". If a documented phrase ever
// stops parsing, this fails loudly rather than silently degrading to an
// "Unrecognised command" toast.

@Suite("Documented command coverage — Commands and Dictation.md")
struct DocumentedCommandCoverageTests {

    private func parses(_ phrase: String) -> Bool {
        TextCommandParser.parse(VoiceCommandRouter.normalise(phrase), original: phrase) != nil
    }

    private func checkAll(_ phrases: [String]) {
        for phrase in phrases {
            #expect(parses(phrase), "did not parse: \u{201C}\(phrase)\u{201D}")
        }
    }

    /// The unit words used across the counted/directional forms.
    private static let units = ["character", "word", "sentence", "paragraph", "line"]

    @Test("Text Selection — every documented phrase parses")
    func selection() {
        var phrases = ["Select that", "Select all", "Select the target phrase",
                       "Select previous", "Select next", "Deselect that"]
        for u in Self.units {
            phrases += ["Select \(u)", "Select previous \(u)", "Select next \(u)",
                        "Select 3 \(u)s", "Select previous 3 \(u)s", "Select next 3 \(u)s",
                        "Extend selection 3 \(u)s", "Extend selection back 3 \(u)s"]
        }
        checkAll(phrases)
    }

    @Test("Text Navigation — every documented phrase parses")
    func navigation() {
        var phrases = ["Move down", "Move up", "Move left", "Move right",
                       "Scroll up", "Scroll down", "Scroll to top", "Scroll to bottom",
                       "Move to beginning", "Move to end",
                       "Move to beginning of selection", "Move to end of selection",
                       "Move after the target phrase", "Move before the target phrase"]
        for u in Self.units {
            phrases += ["Move to beginning of \(u)", "Move to end of \(u)",
                        "Move forward 3 \(u)s", "Move back 3 \(u)s",
                        "Move right 3 \(u)s", "Move left 3 \(u)s"]
        }
        checkAll(phrases)
    }

    @Test("Text Editing — every documented phrase parses")
    func editing() {
        checkAll(["Replace the target phrase with a new phrase",
                  "Insert a new phrase after the target phrase",
                  "Insert a new phrase before the target phrase",
                  "Correct that", "Correct the target phrase",
                  "Undo that", "Redo that", "Cut that", "Copy that", "Paste that",
                  "Capitalise that", "Capitalise the target phrase",
                  "Lowercase that", "Lowercase the target phrase",
                  "Uppercase that", "Uppercase the target phrase",
                  "Bold that", "Bold the target phrase",
                  "Italicise that", "Italicise the target phrase",
                  "Underline that", "Underline the target phrase"])
    }

    @Test("Text Deletion — every documented phrase parses")
    func deletion() {
        var phrases = ["Delete that", "Delete all", "Delete the target phrase"]
        for u in Self.units {
            phrases += ["Delete \(u)", "Delete previous \(u)", "Delete next \(u)",
                        "Delete 3 \(u)s", "Delete previous 3 \(u)s", "Delete next 3 \(u)s"]
        }
        checkAll(phrases)
    }
}
