import AppKit
import Testing
import VoiceChatKit
@testable import VoiceChatUI

@MainActor
@Suite("Conversation model — history and turn commit")
struct ConversationModelTests {

    private func modelAtResponse(_ markdown: String) -> ConversationModel {
        let m = ConversationModel()
        m.open()
        m.promptText = NSAttributedString(string: "tell me a joke")
        m.send()
        m.present(response: markdown)
        return m
    }

    @Test("R-TXT-9 — an untouched response is not marked edited")
    func untouchedIsNotEdited() {
        let m = modelAtResponse("You said: **tell me a joke**\n\nThat is all.")
        m.gotIt()
        #expect(m.history.count == 1)
        #expect(m.history[0].responseWasEdited == false,
                "formatting is not an edit; only the person editing the pane is")
    }

    @Test("R-TXT-9 — a response the person changes is marked edited")
    func touchedIsEdited() {
        let m = modelAtResponse("You said: **tell me a joke**")
        m.responseText = NSAttributedString(string: "I rewrote this myself")
        m.gotIt()
        #expect(m.history[0].responseWasEdited == true)
    }

    @Test("history keeps raw Markdown for export but previews rendered text")
    func previewIsRendered() {
        let m = modelAtResponse("You said: **tell me a joke**")
        m.gotIt()
        let entry = m.history[0]
        #expect(entry.response.contains("**"), "export keeps the original Markdown")
        #expect(!entry.responsePreview.contains("**"), "the preview shows rendered text")
        #expect(entry.responsePreview.contains("tell me a joke"))
    }

    @Test("R-FSM-9 — committing a turn clears both panes and advances")
    func commitClearsPanes() {
        let m = modelAtResponse("an answer")
        #expect(m.turn == 1)
        m.gotIt()
        #expect(m.turn == 2)
        #expect(m.plainPrompt.isEmpty)
        #expect(m.plainResponse.isEmpty)
        #expect(m.state == .composing)
    }

    @Test("R-UI-12 — returning from history restores the draft exactly")
    func historyRestoresDraft() {
        let m = modelAtResponse("an answer")
        m.gotIt()
        m.promptText = NSAttributedString(string: "a draft I was in the middle of")

        m.showHistoryTurn(1)
        #expect(m.isViewingHistory)
        #expect(m.plainPrompt == "tell me a joke")
        #expect(m.promptIsEditable, "a past prompt can be revised and resent")
        #expect(!m.responseIsEditable, "a past response is immutable")

        m.returnToCurrentTurn()
        #expect(!m.isViewingHistory)
        #expect(m.plainPrompt == "a draft I was in the middle of")
    }

    @Test("R-UI-12 — sending a revised past prompt supersedes the draft")
    func sendingFromHistoryDiscardsDraft() {
        let m = modelAtResponse("an answer")
        m.gotIt()
        m.promptText = NSAttributedString(string: "a draft I was in the middle of")

        m.showHistoryTurn(1)
        m.promptText = NSAttributedString(string: "tell me a joke, but a better one")
        var submitted: String?
        m.onSubmitPrompt = { submitted = $0 }
        m.send()

        #expect(submitted == "tell me a joke, but a better one")
        #expect(!m.isViewingHistory)
        #expect(m.state == .submitted)
    }

    @Test("history peeking is just text in the prompt pane — dictation stays available")
    func dictationStaysActiveWhilePeekingHistory() {
        let m = modelAtResponse("an answer")
        m.gotIt()
        #expect(m.canToggleMic)

        m.showHistoryTurn(1)
        #expect(m.isViewingHistory)
        #expect(m.canToggleMic, "mic toggle should not be gated on history peeking")
        #expect(m.canChangeVoiceMode, "mode control should not be gated on history peeking")
    }

    @Test("R-UI-7 — an empty prompt is never sent")
    func emptyPromptNotSent() {
        let m = ConversationModel()
        m.open()
        var submitted: String?
        m.onSubmitPrompt = { submitted = $0 }
        m.promptText = NSAttributedString(string: "   \n  ")
        m.send()
        #expect(submitted == nil)
        #expect(m.state == .composing)
    }

    @Test("R-UI-6 — a pending speech hypothesis is never sent")
    func volatileNeverSent() {
        let m = ConversationModel()
        m.open()
        var submitted: String?
        m.onSubmitPrompt = { submitted = $0 }

        m.promptText = NSAttributedString(string: "what I actually typed")
        m.setVolatile("and a half-heard phrase")
        m.send()

        #expect(submitted == "what I actually typed")
        #expect(m.volatileText.isEmpty, "sending discards the hypothesis")
    }

    @Test("R-STT-6 — dictation in dictation mode is inserted as text")
    func dictationInserts() {
        let m = ConversationModel()
        m.open()
        m.handleFinalUtterance("tell me a joke")
        #expect(m.plainPrompt == "tell me a joke")
        m.handleFinalUtterance("and another")
        #expect(m.plainPrompt == "tell me a joke and another")
    }

    @Test("R-STT-9 — a mode switch is obeyed and never typed")
    func modeSwitchNotTyped() {
        let m = ConversationModel()
        m.open()
        #expect(m.voiceMode == .dictation)
        m.handleFinalUtterance("command mode")
        #expect(m.voiceMode == .command)
        #expect(m.plainPrompt.isEmpty, "the phrase must not appear in the prompt")
        m.handleFinalUtterance("dictation mode")
        #expect(m.voiceMode == .dictation)
        #expect(m.plainPrompt.isEmpty)
    }

    @Test("command-mode interim goes to the command box, not the pane ghost")
    func commandInterimUsesBox() {
        let m = ConversationModel()
        m.open()
        m.setVoiceMode(.command)
        m.setVolatile("select all")
        #expect(m.commandLine == "select all")
        #expect(m.volatileText.isEmpty, "command speech must not ghost the pane")
    }

    @Test("dictation-mode interim ghosts the pane, not the command box")
    func dictationInterimUsesGhost() {
        let m = ConversationModel()
        m.open()   // starts in dictation
        m.setVolatile("hello there")
        #expect(m.volatileText == "hello there")
        #expect(m.commandLine.isEmpty)
    }

    @Test("switching modes clears any pending interim")
    func modeSwitchClearsInterim() {
        let m = ConversationModel()
        m.open()
        m.setVolatile("hello")            // dictation ghost
        m.setVoiceMode(.command)
        #expect(m.volatileText.isEmpty)
        #expect(m.commandLine.isEmpty)
    }

    @Test("R-STT-11 — an unrecognised command is reported, never typed")
    func unrecognisedCommandNotTyped() {
        let m = ConversationModel()
        m.open()
        m.setVoiceMode(.command)
        m.handleFinalUtterance("wibble wobble")
        #expect(m.plainPrompt.isEmpty)
        #expect(m.commandToast?.contains("Unrecognised") == true)
    }

    @Test("R-STT-17 — an unavailable command reads differently from an unknown one")
    func unavailableCommand() {
        let m = ConversationModel()
        m.open()
        m.setVoiceMode(.command)
        m.handleFinalUtterance("play")          // nothing to play while composing
        #expect(m.commandToast?.contains("not available") == true)
    }

    @Test("\"send prompt\" submits from command mode")
    func sendPromptByVoice() {
        let m = ConversationModel()
        m.open()
        var submitted: String?
        m.onSubmitPrompt = { submitted = $0 }
        m.promptText = NSAttributedString(string: "a spoken prompt")
        m.setVoiceMode(.command)
        m.handleFinalUtterance("send prompt")
        #expect(submitted == "a spoken prompt")
        #expect(m.state == .submitted)
    }

    @Test("R-TTS-4 — the recogniser is stopped before speech and restarted after")
    func micInterlock() {
        let m = ConversationModel()
        m.speechAvailable = true
        var actions: [RecognizerAction] = []
        m.onRecognizer = { actions.append($0) }
        m.open()
        m.promptText = NSAttributedString(string: "hello")
        m.send()
        actions.removeAll()

        m.present(response: "a spoken answer")
        #expect(actions.contains(.stop), "the mic must be torn down before speaking")
        #expect(!actions.contains { if case .start = $0 { return true } else { return false } },
                "the mic must not come back while speech is playing")

        actions.removeAll()
        m.stop()
        // R-TTS-5 — Stop returns the recogniser in Command mode.
        #expect(actions.contains(.start(.command)))
    }

    @Test("R-UI-19 — confirmation is only needed when there is work to lose")
    func confirmationOnlyWhenNeeded() {
        let m = ConversationModel()
        m.open()
        #expect(m.endNeedsConfirmation == false)
        m.promptText = NSAttributedString(string: "half a thought")
        #expect(m.endNeedsConfirmation == true)
    }
}
