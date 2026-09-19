import Testing
@testable import VoiceChatKit

// Spec §15.2 — table-driven over the §5.2 transition table, asserting the
// resulting state *and* every effect column.

@Suite("Session machine — §5.2 transition table")
struct SessionMachineTableTests {

    private func opened() -> SessionMachine {
        var m = SessionMachine()
        m.handle(.sessionOpened)
        return m
    }

    private func responding() -> SessionMachine {
        var m = opened()
        m.handle(.send(isEmpty: false))
        m.handle(.responseReceived(isEmpty: false))
        return m
    }

    @Test("row 1 — open starts composing, turn 1, dictation")
    func row1() {
        var m = SessionMachine()
        let t = m.handle(.sessionOpened)
        #expect(t.row == 1)
        #expect(m.state == .composing)
        #expect(m.turn == 1)
        #expect(m.voiceMode == .dictation)
        #expect(t.effects.recognizer == .start(.dictation))
    }

    @Test("row 2 — send submits and stops the recogniser")
    func row2() {
        var m = opened()
        let t = m.handle(.send(isEmpty: false))
        #expect(t.row == 2)
        #expect(m.state == .submitted)
        #expect(t.effects.recognizer == .stop)
        #expect(t.effects.submitsPrompt)
    }

    @Test("row 3 — empty send is rejected, never submitted")
    func row3() {
        var m = opened()
        let t = m.handle(.send(isEmpty: true))
        #expect(t.row == 3)
        #expect(m.state == .composing)
        #expect(t.effects.rejectsEmptySend)
        #expect(!t.effects.submitsPrompt)
    }

    @Test("row 6 — a response starts speaking with the mic off")
    func row6() {
        var m = opened()
        m.handle(.send(isEmpty: false))
        let t = m.handle(.responseReceived(isEmpty: false))
        #expect(t.row == 6)
        #expect(m.state == .respondingAuto)
        #expect(t.effects.recognizer == .stop)
        #expect(t.effects.speech == .start)
    }

    @Test("row 7 — an empty response never enters a Responding state")
    func row7() {
        var m = opened()
        m.handle(.send(isEmpty: false))
        let t = m.handle(.responseReceived(isEmpty: true))
        #expect(t.row == 7)
        #expect(m.state == .composing)
        #expect(m.turn == 2)
        #expect(t.effects.speech == .unchanged)
    }

    @Test("row 8 — finishing in Auto advances the turn")
    func row8() {
        var m = responding()
        let t = m.handle(.speechFinished)
        #expect(t.row == 8)
        #expect(m.state == .composing)
        #expect(m.turn == 2)
        #expect(m.voiceMode == .dictation)
        #expect(t.effects.advancesTurn)
        #expect(t.effects.commitsTurnToHistory)
        #expect(t.effects.clearsPanes)
    }

    @Test("row 9 — Stop latches into Manual and returns voice to Command mode")
    func row9() {
        var m = responding()
        let t = m.handle(.stop)
        #expect(t.row == 9)
        #expect(m.state == .respondingManual)
        #expect(m.voiceMode == .command)
        #expect(t.effects.speech == .stop)
        #expect(t.effects.recognizer == .start(.command))
    }

    @Test("row 11 — finishing in Manual does NOT advance the turn")
    func row11() {
        var m = responding()
        m.handle(.stop)
        m.handle(.play)
        let t = m.handle(.speechFinished)
        #expect(t.row == 11)
        #expect(m.state == .respondingManual)
        #expect(m.turn == 1)
        #expect(m.voiceMode == .command)
    }

    @Test("rows 10/12 — Play and Stop may repeat indefinitely without advancing")
    func playStopLoop() {
        var m = responding()
        m.handle(.stop)
        for _ in 0..<10 {
            #expect(m.handle(.play).row == 10)
            #expect(m.handle(.stop).row == 12)
        }
        #expect(m.state == .respondingManual)
        #expect(m.turn == 1)
    }

    @Test("row 13 — Got it! is the only way out of Manual")
    func row13() {
        var m = responding()
        m.handle(.stop)
        let t = m.handle(.gotIt)
        #expect(t.row == 13)
        #expect(m.state == .composing)
        #expect(m.turn == 2)
        #expect(m.voiceMode == .dictation)
        #expect(t.effects.speech == .stop)
    }

    @Test("row 14 — ending is terminal and every later event is ignored")
    func row14() {
        var m = responding()
        let t = m.handle(.end(.userEnded))
        #expect(t.row == 14)
        #expect(m.state == .ended(.userEnded))
        #expect(t.effects.closesSession == .userEnded)

        for event: SessionEvent in [.play, .stop, .gotIt, .send(isEmpty: false), .sessionOpened] {
            #expect(m.handle(event).isIgnored, "\(event) should be ignored after end")
        }
        #expect(m.state == .ended(.userEnded))
    }

    @Test("R-UI-24 — with auto-play off, a response lands in Manual directly")
    func autoPlayOff() {
        var m = SessionMachine()
        m.autoPlayEnabled = false
        m.handle(.sessionOpened)
        m.handle(.send(isEmpty: false))
        let t = m.handle(.responseReceived(isEmpty: false))
        #expect(m.state == .respondingManual)
        #expect(t.effects.speech == .unchanged)
    }

    @Test("R-FSM-2 — the manual latch resets at every turn boundary")
    func latchResets() {
        var m = responding()
        m.handle(.stop)
        m.handle(.gotIt)
        m.handle(.send(isEmpty: false))
        m.handle(.responseReceived(isEmpty: false))
        #expect(m.state == .respondingAuto, "a new turn must start in Auto")
    }
}

@Suite("Session machine — §5.3 invariants")
struct SessionMachineInvariantTests {

    /// R-FSM-3 / R-FSM-4 — the recogniser never runs while anything is spoken.
    @Test("the recogniser is never live while speech is playing")
    func micNeverLiveWhileSpeaking() {
        var m = SessionMachine()
        let events: [SessionEvent] = [
            .sessionOpened, .send(isEmpty: false), .responseReceived(isEmpty: false),
            .play, .stop, .play, .speechFinished, .gotIt,
            .send(isEmpty: false), .responseReceived(isEmpty: false), .stop, .play,
            .speechCancelled, .gotIt,
        ]
        for event in events {
            m.handle(event)
            if m.isSpeaking {
                #expect(!m.recognizerShouldRun, "recogniser live while speaking, after \(event)")
            }
            if m.state == .submitted || m.state == .respondingAuto {
                #expect(!m.recognizerShouldRun, "recogniser live in \(m.state)")
            }
        }
    }

    /// R-FSM-7 — the turn counter only ever increases, by one.
    @Test("the turn counter is monotonic and never skips")
    func turnMonotonic() {
        var m = SessionMachine()
        var last = 0
        let events: [SessionEvent] = [
            .sessionOpened, .send(isEmpty: true), .send(isEmpty: false),
            .responseReceived(isEmpty: false), .speechFinished,
            .send(isEmpty: false), .responseReceived(isEmpty: true),
            .send(isEmpty: false), .responseReceived(isEmpty: false), .stop, .gotIt,
        ]
        for event in events {
            let t = m.handle(event)
            #expect(m.turn >= last)
            if t.effects.advancesTurn { #expect(m.turn == last + 1) }
            last = m.turn
        }
    }

    /// R-FSM-6 — focus follows state.
    @Test("focus follows state")
    func focusFollowsState() {
        var m = SessionMachine()
        m.handle(.sessionOpened)
        #expect(m.focusedPane == .prompt)
        m.handle(.send(isEmpty: false))
        m.handle(.responseReceived(isEmpty: false))
        #expect(m.focusedPane == .response)
        m.handle(.gotIt)
        #expect(m.focusedPane == .prompt)
    }
}
