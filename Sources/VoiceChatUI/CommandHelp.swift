import SwiftUI

// A human-readable catalogue of every supported voice command, shown in the
// Help popover next to the mode control. Kept in sync with
// `Commands and Dictation.md` (the authoritative grammar) and the dispatch in
// VoiceCommandRouter / TextCommandParser.

struct CommandHelpItem: Identifiable {
    let id = UUID()
    let phrase: String
    let detail: String
}

struct CommandHelpGroup: Identifiable {
    let id = UUID()
    let title: String
    let note: String?
    let items: [CommandHelpItem]

    init(_ title: String, note: String? = nil, _ items: [CommandHelpItem]) {
        self.title = title
        self.note = note
        self.items = items
    }
}

enum CommandReference {
    private static func i(_ phrase: String, _ detail: String) -> CommandHelpItem {
        CommandHelpItem(phrase: phrase, detail: detail)
    }

    /// `<phrase>` is spoken text; `<n>` is a number (1–20, or digits). Units are
    /// character, word, sentence, paragraph, line.
    static let groups: [CommandHelpGroup] = [
        CommandHelpGroup("Voice Modes", note: "Recognised in either mode; never typed.", [
            i("Command mode", "Switch to issuing commands."),
            i("Dictation mode", "Switch to dictating text."),
        ]),
        CommandHelpGroup("System & Session", [
            i("Send prompt", "Submit the prompt to the assistant."),
            i("Stop", "Stop the spoken reply."),
            i("Play", "Play or resume the spoken reply."),
            i("Got it", "Acknowledge the reply and start the next turn."),
        ]),
        CommandHelpGroup("Selection", [
            i("Select that", "Select the current word if nothing is selected."),
            i("Select all", "Select the whole pane."),
            i("Select <phrase>", "Select the nearest match."),
            i("Select previous / next", "Select the previous or next word."),
            i("Select [previous|next] <unit>", "e.g. “Select next sentence”."),
            i("Select [previous|next] <n> <units>", "e.g. “Select 3 words”."),
            i("Extend selection [back] <n> <units>", "Grow the selection forward or back."),
            i("Deselect that", "Clear the selection."),
        ]),
        CommandHelpGroup("Navigation", [
            i("Move up / down / left / right", "Move the caret by line or character."),
            i("Move to beginning / end", "Jump to the start or end of the pane."),
            i("Move to [beginning|end] of <unit>", "e.g. “Move to end of line”."),
            i("Move to [beginning|end] of selection", "Collapse to a selection edge."),
            i("Move [forward|back|right|left] <n> <units>", "e.g. “Move back 2 words”."),
            i("Move after / before <phrase>", "Place the caret around a match."),
            i("Scroll up / down", "Scroll one page."),
            i("Scroll to top / bottom", "Scroll to either end."),
        ]),
        CommandHelpGroup("Editing", note: "On either pane when it can be edited.", [
            i("Replace <phrase> with <phrase>", "Swap text."),
            i("Insert <phrase> after / before <phrase>", "Insert around a match."),
            i("Correct that / Correct <phrase>", "Open the spelling/grammar panel."),
            i("Undo that / Redo that", "Undo or redo the last edit."),
            i("Cut that / Copy that / Paste that", "Clipboard actions."),
            i("Capitalise / Lowercase / Uppercase that", "Change case of the selection."),
            i("Capitalise / Lowercase / Uppercase <phrase>", "Change case of a match."),
            i("Bold / Italicise / Underline that", "Format the selection."),
            i("Bold / Italicise / Underline <phrase>", "Format a match."),
        ]),
        CommandHelpGroup("Deletion", [
            i("Delete that", "Delete the selection."),
            i("Delete all", "Delete everything in the pane."),
            i("Delete <phrase>", "Delete the nearest match."),
            i("Delete [previous|next] <unit>", "e.g. “Delete previous word”."),
            i("Delete [previous|next] <n> <units>", "e.g. “Delete 2 lines”."),
        ]),
        CommandHelpGroup("Dictation", note: "Spoken while in dictation mode.", [
            i("Type <phrase>", "Insert text verbatim, no auto-formatting."),
            i("<phrase> emoji", "Insert an emoji, e.g. “fire emoji”."),
            i("Insert date", "Insert today’s date."),
            i("Press return key", "Insert a new line."),
            i("Press escape key", "Dismiss the pending hypothesis."),
            i("Add to vocabulary", "Teach the recogniser the last word."),
            i("Send prompt", "Submit the prompt without leaving dictation."),
        ]),
    ]
}

/// A scrollable, formatted reference of the voice commands. Shown from the Help
/// button beside the mode control.
public struct CommandHelpView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.and.mic")
                    .foregroundStyle(.tint)
                Text("Voice Commands")
                    .font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(CommandReference.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            if let note = group.note {
                                Text(note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.phrase)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    Text(item.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Tip: “<phrase>” is spoken text; “<n>” is a number. Units are character, word, sentence, paragraph, line.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 540)
    }
}
