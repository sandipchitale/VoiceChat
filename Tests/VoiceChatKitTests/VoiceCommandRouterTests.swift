import Testing
@testable import VoiceChatKit

@Suite("Voice command routing — §8.5")
struct VoiceCommandRouterTests {

    @Test("normalisation strips case, padding and trailing punctuation")
    func normalisation() {
        #expect(VoiceCommandRouter.normalise("  Send Prompt.  ") == "send prompt")
        #expect(VoiceCommandRouter.normalise("Command mode!") == "command mode")
        #expect(VoiceCommandRouter.normalise("got   it?") == "got it")
        #expect(VoiceCommandRouter.normalise("don\u{2019}t") == "don't")
    }

    @Test("R-STT-9 — mode switches work in both modes and are never text")
    func modeSwitchesInBothModes() {
        #expect(VoiceCommandRouter.route("command mode", mode: .dictation) == .setMode(.command))
        #expect(VoiceCommandRouter.route("dictation mode", mode: .command) == .setMode(.dictation))
        #expect(VoiceCommandRouter.route("Command Mode.", mode: .dictation) == .setMode(.command))
    }

    @Test("session controls fire in command mode")
    func sessionControls() {
        #expect(VoiceCommandRouter.route("send prompt", mode: .command) == .sendPrompt)
        #expect(VoiceCommandRouter.route("stop", mode: .command) == .stop)
        #expect(VoiceCommandRouter.route("play", mode: .command) == .play)
        #expect(VoiceCommandRouter.route("got it", mode: .command) == .gotIt)
    }

    @Test("ordinary speech in dictation mode is text, not a command")
    func dictationIsText() {
        #expect(VoiceCommandRouter.route("stop", mode: .dictation) == nil)
        #expect(VoiceCommandRouter.route("tell me a joke", mode: .dictation) == nil)
    }

    @Test("`Send prompt` submits from dictation mode, but only as a whole utterance")
    func sendPromptInDictation() {
        #expect(VoiceCommandRouter.route("send prompt", mode: .dictation) == .sendPrompt)
        #expect(VoiceCommandRouter.route("Send the prompt.", mode: .dictation) == .sendPrompt)
        #expect(VoiceCommandRouter.route("please send prompt now", mode: .dictation) == nil)
        #expect(VoiceCommandRouter.route("send prompts", mode: .dictation) == nil)
    }

    @Test("R-STT-11 — an unmatched phrase in command mode is reported, not typed")
    func unrecognisedInCommandMode() {
        #expect(VoiceCommandRouter.route("wibble wobble", mode: .command) == .unrecognised("wibble wobble"))
    }

    @Test("dictation directives from Commands and Dictation.md are honoured")
    func dictationDirectives() {
        #expect(VoiceCommandRouter.route("insert date", mode: .dictation) == .insertDate)
        #expect(VoiceCommandRouter.route("Press Return key", mode: .dictation) == .pressReturn)
        #expect(VoiceCommandRouter.route("press escape key", mode: .dictation) == .pressEscape)
        #expect(VoiceCommandRouter.route("add to vocabulary", mode: .dictation) == .addToVocabulary)
    }

    @Test("`Type <phrase>` keeps the phrase verbatim, not lowercased")
    func typeVerbatim() {
        #expect(VoiceCommandRouter.route("Type Kubernetes", mode: .dictation)
                == .typeVerbatim("Kubernetes"))
    }

    @Test("`<phrase> emoji` resolves through the lexicon")
    func emojiDirective() {
        #expect(VoiceCommandRouter.route("fire emoji", mode: .dictation) == .emoji("fire"))
        #expect(EmojiLexicon.emoji(named: "fire") == "\u{1F525}")
        #expect(EmojiLexicon.emoji(named: "Thumbs Up") == "\u{1F44D}")
        #expect(EmojiLexicon.emoji(named: "not a real name") == nil)
    }

    @Test("directives do not hijack ordinary dictation")
    func directivesDoNotOverreach() {
        #expect(VoiceCommandRouter.route("I typed it myself", mode: .dictation) == nil)
        #expect(VoiceCommandRouter.route("the date is important", mode: .dictation) == nil)
    }

    @Test("an empty utterance does nothing in either mode")
    func emptyUtterance() {
        #expect(VoiceCommandRouter.route("   ", mode: .command) == nil)
        #expect(VoiceCommandRouter.route("", mode: .dictation) == nil)
    }
}
