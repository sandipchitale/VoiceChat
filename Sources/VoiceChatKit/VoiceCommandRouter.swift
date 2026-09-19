import Foundation

// Spec §8.5 — the command dispatch contract.
//
// `Commands and Dictation.md` is authoritative for which phrases exist; this
// file is authoritative for how an utterance is normalised, prioritised and
// dispatched. Groups 1 and 2 of R-STT-14 (mode switches, System & Session
// Controls) are implemented here. Groups 3-6 — selection, navigation, editing,
// deletion — operate on the text document and arrive with the dispatcher.

public enum VoiceCommand: Equatable, Sendable {
    case setMode(VoiceMode)
    case sendPrompt
    case stop
    case play
    case gotIt
    // Dictation Mode directives, per `Commands and Dictation.md`.
    case insertDate
    case pressReturn
    case pressEscape
    case addToVocabulary
    /// `Type <phrase>` — verbatim, bypassing auto-formatting.
    case typeVerbatim(String)
    /// `<phrase> emoji` — e.g. "fire emoji".
    case emoji(String)

    /// Command mode, no match: R-STT-11 forbids inserting this as text.
    case unrecognised(String)
}

/// A small curated table. An unknown name falls through to being dictated
/// literally, which is less surprising than silently inserting nothing.
public enum EmojiLexicon {
    static let table: [String: String] = [
        "fire": "🔥", "heart": "❤️", "smile": "🙂", "smiley": "😀", "grin": "😁",
        "laugh": "😂", "wink": "😉", "thinking": "🤔", "thumbs up": "👍",
        "thumbs down": "👎", "clap": "👏", "wave": "👋", "ok": "👌",
        "check": "✅", "cross": "❌", "warning": "⚠️", "star": "⭐️",
        "rocket": "🚀", "party": "🎉", "eyes": "👀", "shrug": "🤷",
        "hundred": "💯", "bulb": "💡", "bug": "🐛", "sparkles": "✨",
    ]

    public static func emoji(named name: String) -> String? {
        table[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }
}

public enum VoiceCommandRouter {

    /// §8.5 — lowercase, trim, collapse whitespace, strip trailing punctuation,
    /// normalise smart quotes and dashes.
    public static func normalise(_ utterance: String) -> String {
        var text = utterance.lowercased()
        text = text.replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.replacingOccurrences(of: "\u{2018}", with: "'")
        text = text.replacingOccurrences(of: "\u{201C}", with: "\"")
        text = text.replacingOccurrences(of: "\u{201D}", with: "\"")
        text = text.replacingOccurrences(of: "\u{2014}", with: "-")
        text = text.replacingOccurrences(of: "\u{2013}", with: "-")
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while let last = text.last, ".,!?;:".contains(last) {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// R-STT-9 — mode switches are recognised in *both* modes and are never
    /// inserted as text.
    private static let modeSwitches: [String: VoiceMode] = [
        "command mode": .command,
        "commands mode": .command,
        "dictation mode": .dictation,
        "dictate mode": .dictation,
    ]

    /// Group 2 of R-STT-14, matching the System & Session Controls section of
    /// `Commands and Dictation.md`.
    private static let sessionControls: [String: VoiceCommand] = [
        "send prompt": .sendPrompt,
        "send the prompt": .sendPrompt,
        "stop": .stop,
        "play": .play,
        "got it": .gotIt,
        "gotit": .gotIt,
    ]

    /// Returns nil when the utterance is not a command and should be treated as
    /// dictation. Never returns nil in command mode: an unmatched phrase there
    /// is `.unrecognised`, which the caller reports rather than types.
    public static func route(_ utterance: String, mode: VoiceMode) -> VoiceCommand? {
        let text = normalise(utterance)
        guard !text.isEmpty else { return nil }

        // Precedence group 1: mode switches, in either mode.
        if let mode = modeSwitches[text] { return .setMode(mode) }

        switch mode {
        case .dictation:
            // Dictation Mode directives from `Commands and Dictation.md`.
            switch text {
            case "insert date":                       return .insertDate
            case "press return key", "press return":  return .pressReturn
            case "press escape key", "press escape":  return .pressEscape
            case "add to vocabulary":                 return .addToVocabulary
            // Only the whole utterance counts, like a mode switch: a sentence that
            // merely contains these words is still dictation.
            case "send prompt", "send the prompt":    return .sendPrompt
            default: break
            }
            if text.hasPrefix("type "), text.count > 5 {
                // Verbatim, so take the phrase from the *original* utterance
                // rather than the lowercased, punctuation-stripped form.
                let original = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
                let phrase = String(original.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return .typeVerbatim(phrase.isEmpty ? String(text.dropFirst(5)) : phrase)
            }
            if text.hasSuffix(" emoji") {
                return .emoji(String(text.dropLast(6)))
            }
            // Everything else is speech to be typed. The other session controls
            // are deliberately not matched here: "stop" is an ordinary English
            // word and swallowing it mid-sentence would be worse than useless.
            // "Send prompt" is the exception — a distinctive two-word phrase that
            // is worth being able to say without leaving dictation.
            return nil

        case .command:
            if let command = sessionControls[text] { return command }
            return .unrecognised(text)
        }
    }
}
