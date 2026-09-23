import Foundation
import Testing
@testable import VoiceChatKit

@Suite("Debate rules — whose turn it is, without a window in sight")
struct DebateMachineTests {

    private func room(maxStatements: Int = 10) -> DebateRoom {
        DebateRoom(id: "owl-42",
                   motion: "AI should write its own tests",
                   seats: [
                       DebateSeat(key: "for", name: "For the motion", position: "yes, always"),
                       DebateSeat(key: "against", name: "Against the motion", position: "no, humans must"),
                   ],
                   maxStatements: maxStatements)
    }

    /// Whatever a `deliver` effect would put in a prompt pane.
    private func delivered(_ effects: [DebateEffect]) -> (seat: String, text: String, autoSend: Bool)? {
        for effect in effects {
            if case .deliver(let seat, let text, let autoSend) = effect {
                return (seat, text, autoSend)
            }
        }
        return nil
    }

    @Test("nothing happens until every seat is taken")
    func waitsForSeats() {
        var m = DebateMachine(room: room())
        let first = m.handle(.seatFilled("for"))
        #expect(delivered(first) == nil)
        #expect(m.phase == .awaitingSeats)
        #expect(m.filledSeats == 1)

        let second = m.handle(.seatFilled("against"))
        let opening = delivered(second)
        #expect(opening?.seat == "for", "the first seat opens")
        #expect(opening?.text.contains("You open the debate") == true)
        #expect(opening?.text.contains("AI should write its own tests") == true)
        #expect(m.phase == .awaitingSend(seat: "for"))
    }

    @Test("a statement is delivered un-sent, and waits for the moderator")
    func deliveriesWaitForSend() {
        var m = DebateMachine(room: room())
        m.handle(.seatFilled("for"))
        m.handle(.seatFilled("against"))
        #expect(delivered(m.handle(.statementCompleted(seat: "for", text: "too early")))  == nil,
                "the opening prompt has not even been sent yet")

        m.handle(.promptSent(seat: "for"))
        #expect(m.phase == .awaitingStatement(seat: "for"))

        let handover = delivered(m.handle(.statementCompleted(seat: "for", text: "For here. Tests are code.")))
        #expect(handover?.seat == "against")
        #expect(handover?.autoSend == false, "the moderator presses Send")
        #expect(handover?.text.contains("For here. Tests are code.") == true)
        #expect(m.phase == .awaitingSend(seat: "against"))
    }

    @Test("the rules are given to each seat exactly once")
    func briefsEachSeatOnce() {
        var m = DebateMachine(room: room())
        m.handle(.seatFilled("for"))
        m.handle(.seatFilled("against"))
        m.handle(.promptSent(seat: "for"))

        let first = delivered(m.handle(.statementCompleted(seat: "for", text: "one")))
        #expect(first?.text.contains("you argue this position") == true,
                "the second seat has not been told the rules until now")

        m.handle(.promptSent(seat: "against"))
        let second = delivered(m.handle(.statementCompleted(seat: "against", text: "two")))
        #expect(second?.text.contains("you argue this position") == false,
                "the first seat was briefed when it opened")
        #expect(second?.text.contains("two") == true)
    }

    @Test("turns alternate for the whole budget, then every seat gets a closing")
    func alternatesThenCloses() {
        var m = DebateMachine(room: room(maxStatements: 4))
        m.handle(.seatFilled("for"))
        m.handle(.seatFilled("against"))

        var speaking = "for"
        var order: [String] = []
        var closingPrompts = 0
        var ended = false

        for statement in 1...6 {
            m.handle(.promptSent(seat: speaking))
            order.append(speaking)
            let effects = m.handle(.statementCompleted(seat: speaking, text: "statement \(statement)"))
            if effects.contains(.endAll) { ended = true; break }
            guard let next = delivered(effects) else { break }
            if next.text.contains("final exchange") { closingPrompts += 1 }
            speaking = next.seat
        }

        #expect(order == ["for", "against", "for", "against", "for", "against"])
        #expect(closingPrompts == 2, "one closing statement per seat")
        #expect(ended)
        #expect(m.phase == .ended)
        #expect(m.statementCount == 4)
    }

    @Test("a seat leaving ends the debate once, and later events are inert")
    func seatLeavingEndsItOnce() {
        var m = DebateMachine(room: room())
        m.handle(.seatFilled("for"))
        m.handle(.seatFilled("against"))
        m.handle(.promptSent(seat: "for"))

        let ending = m.handle(.seatEnded(seat: "against"))
        #expect(ending.contains(.endAll))
        #expect(m.phase == .ended)

        #expect(m.handle(.seatEnded(seat: "for")).isEmpty, "no second end")
        #expect(m.handle(.statementCompleted(seat: "for", text: "hello?")).isEmpty)
    }

    @Test("Skip turn offers the last statement again")
    func skipTurnRepeats() {
        var m = DebateMachine(room: room())
        m.handle(.seatFilled("for"))
        m.handle(.seatFilled("against"))
        m.handle(.promptSent(seat: "for"))
        m.handle(.statementCompleted(seat: "for", text: "my point stands"))

        let again = delivered(m.handle(.skipTurn))
        #expect(again?.seat == "against")
        #expect(again?.text.contains("my point stands") == true)
    }

    @Test("a statement from a seat that does not have the floor is ignored")
    func ignoresOutOfTurnStatements() {
        var m = DebateMachine(room: room())
        m.handle(.seatFilled("for"))
        m.handle(.seatFilled("against"))
        m.handle(.promptSent(seat: "for"))

        #expect(m.handle(.statementCompleted(seat: "against", text: "interrupting")).isEmpty)
        #expect(m.statementCount == 0)
    }
}

@Suite("Debate wording — what each debater is actually told")
struct DebateRoomTests {

    private let room = DebateRoom(
        id: "owl-42",
        motion: "AI should write its own tests",
        seats: [DebateSeat(key: "for", name: "For the motion", position: "yes, always"),
                DebateSeat(key: "against", name: "Against the motion", position: "no, humans must")],
        maxStatements: 6,
        guidance: "Keep each statement under 120 words.")

    @Test("the briefing carries the motion, the position and the house rules")
    func briefing() {
        let text = room.briefing(for: room.seats[0])
        #expect(text.contains("AI should write its own tests"))
        #expect(text.contains("yes, always"))
        #expect(text.contains("Keep each statement under 120 words."))
        #expect(text.contains("naming yourself"), "each statement announces its speaker")
        #expect(text.contains("read aloud"))
    }

    @Test("the join instruction names the id and the seat")
    func joinInstruction() {
        let text = room.joinInstruction(for: room.seats[1])
        #expect(text.contains("\"owl-42\""))
        #expect(text.contains("\"against\""))
        #expect(text.contains("converse"))
        #expect(text.contains("AI should write its own tests"))
    }

    @Test("a moderator's words are marked as the moderator's")
    func moderatorLine() {
        #expect(DebateRoom.moderatorLine("  answer the question  ") == "> Moderator: answer the question")
        #expect(DebateRoom.moderatorLine("one\ntwo") == "> Moderator: one\n> two")
    }

    @Test("seats speak in a rotation, so a third seat would need no new rule")
    func rotation() {
        #expect(room.seat(after: "for")?.key == "against")
        #expect(room.seat(after: "against")?.key == "for")
        #expect(room.openingSeat?.key == "for")
    }

    @Test("room ids are short enough to retype in another app")
    func ids() {
        let id = DebateRoom.makeID()
        #expect(id.count <= 8)
        #expect(id.contains("-"))
    }
}

@Suite("Moderator edits — whose words are whose")
struct DebateModeratorEditTests {

    @Test("an untouched statement goes out exactly as it arrived")
    func untouched() {
        let text = "For here. Tests are code."
        #expect(DebateRoom.markModeratorEdits(sent: text, delivered: text) == text)
    }

    @Test("a question added underneath is marked as the moderator's")
    func appended() {
        let out = DebateRoom.markModeratorEdits(
            sent: "Against here. A test nobody read is not a test.\n\nAnswer the cost point.",
            delivered: "Against here. A test nobody read is not a test.")
        #expect(out == "Against here. A test nobody read is not a test.\n\n> Moderator: Answer the cost point.")
    }

    @Test("text put above the statement is marked too")
    func prepended() {
        let out = DebateRoom.markModeratorEdits(sent: "Be brief.\n\nthe statement",
                                                delivered: "the statement")
        #expect(out == "> Moderator: Be brief.\n\nthe statement")
    }

    @Test("a statement replaced outright is all the moderator's")
    func replaced() {
        let out = DebateRoom.markModeratorEdits(sent: "Forget that. Talk about cost.",
                                                delivered: "the original statement")
        #expect(out == "> Moderator: Forget that. Talk about cost.")
    }

    @Test("an ordinary prompt with nothing delivered is untouched")
    func noDelivery() {
        #expect(DebateRoom.markModeratorEdits(sent: "just typing", delivered: nil) == "just typing")
    }
}
