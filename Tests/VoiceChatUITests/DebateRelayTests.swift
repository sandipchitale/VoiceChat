import AppKit
import Testing
import VoiceChatKit
@testable import VoiceChatUI

// R-DEB-1 — the seam a debate relays on. A finished statement must surface
// exactly once per turn, whatever ended the turn: speech finishing, "Got it!",
// or an empty response. Nothing here touches audio, which is the point: the
// relay must behave identically muted.

@MainActor
@Suite("Debate relay seam — a finished statement reaches the next window")
struct DebateRelayTests {

    /// A model with a stand-in synthesiser: speaking finishes on the next tick.
    private func speakingModel() -> ConversationModel {
        let m = ConversationModel(micEnabled: false)
        m.speechAvailable = true
        m.onStartSpeech = { [weak m] _, _ in
            Task { @MainActor in m?.speechFinished() }
        }
        m.open()
        return m
    }

    /// One turn: the person's prompt, then the assistant's answer.
    private func runTurn(_ m: ConversationModel, prompt: String, response: String) {
        m.submitPrompt(prompt)
        m.present(response: response)
    }

    /// The hook fires a tick late on purpose, so tests wait for it.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test("a statement read aloud reaches the hook once, with its turn")
    func relaysAfterSpeaking() async {
        let m = speakingModel()
        var seen: [(String, Int)] = []
        m.onTurnAdvanced = { seen.append(($0, $1)) }

        runTurn(m, prompt: "your opening statement", response: "Claude Code, for the motion.")
        await settle()

        #expect(seen.count == 1)
        #expect(seen.first?.0 == "Claude Code, for the motion.")
        #expect(seen.first?.1 == 1)
        #expect(m.turn == 2)
    }

    @Test("muting changes nothing about the relay")
    func relaysWhileMuted() async {
        let wasMuted = GlassSettings.shared.speechMuted
        GlassSettings.shared.speechMuted = true
        defer { GlassSettings.shared.speechMuted = wasMuted }

        let m = speakingModel()
        var seen: [String] = []
        m.onTurnAdvanced = { statement, _ in seen.append(statement) }

        runTurn(m, prompt: "first", response: "statement one")
        await settle()
        runTurn(m, prompt: "second", response: "statement two")
        await settle()

        #expect(seen == ["statement one", "statement two"],
                "the relay hangs off the turn advancing, never off audio")
    }

    @Test("R-UI-24 — with auto-play off, Got it! still relays")
    func relaysWithoutAutoPlay() async {
        let m = ConversationModel(micEnabled: false)
        m.speechAvailable = false          // VoiceOver, or no installed voices
        m.open()
        var seen: [String] = []
        m.onTurnAdvanced = { statement, _ in seen.append(statement) }

        runTurn(m, prompt: "your turn", response: "a statement nobody read aloud")
        await settle()
        #expect(seen.isEmpty, "nothing has finished yet — the turn waits for Got it!")

        m.gotIt()
        await settle()
        #expect(seen == ["a statement nobody read aloud"])
    }

    @Test("the statement is captured before the turn is committed")
    func capturesBeforeCommit() async {
        let m = speakingModel()
        var seen: String?
        m.onTurnAdvanced = { statement, _ in seen = statement }

        runTurn(m, prompt: "go", response: "**bold** statement")
        await settle()

        #expect(seen == "**bold** statement", "the raw Markdown, as received")
        #expect(m.receivedResponse.isEmpty, "committing the turn cleared it afterwards")
        #expect(m.history.count == 1)
    }

    @Test("an edited response relays what was actually read out")
    func relaysTheEditedText() async {
        let m = ConversationModel(micEnabled: false)
        m.speechAvailable = false
        m.open()
        var seen: String?
        m.onTurnAdvanced = { statement, _ in seen = statement }

        runTurn(m, prompt: "go", response: "the original wording")
        m.responseText = NSAttributedString(string: "the moderator's wording")
        m.gotIt()
        await settle()

        #expect(seen == "the moderator's wording")
        #expect(m.history[0].responseWasEdited, "history still records it as edited")
        #expect(m.history[0].response == "the original wording",
                "history still keeps the response as received")
    }

    @Test("an empty response advances and still relays, rather than stranding the debate")
    func relaysEmptyStatement() async {
        let m = speakingModel()
        var fired = 0
        m.onTurnAdvanced = { _, _ in fired += 1 }

        runTurn(m, prompt: "go", response: "   ")
        await settle()

        #expect(fired == 1)
        #expect(m.turn == 2)
    }

    @Test("a delivered statement can wait in the pane until Send")
    func submitPromptCanHold() async {
        let m = speakingModel()
        var fired = 0
        m.onTurnAdvanced = { _, _ in fired += 1 }

        m.submitPrompt("your opponent said this", autoSend: false)
        #expect(m.plainPrompt == "your opponent said this")
        #expect(m.state == .composing, "nothing was sent yet")
        #expect(m.canSend)

        m.send()
        m.present(response: "and here is my reply")
        await settle()
        #expect(fired == 1)
    }
}
