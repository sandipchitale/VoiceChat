import Foundation
import Testing
import VoiceChatKit
@testable import VoiceChatUI

/// A seat with no window, no peer and no synthesiser.
@MainActor
final class FakeParticipant: DebateParticipant {
    let seatKey: String
    var pane = ""
    var sentCount = 0
    var badge: DebateBadge?
    var ended = false

    var onStatementCompleted: ((String) -> Void)?
    var onPromptSent: (() -> Void)?
    var onSessionEnded: (() -> Void)?

    init(_ seatKey: String) { self.seatKey = seatKey }

    func deliver(_ text: String, autoSend: Bool) {
        pane = text
        if autoSend { send() }
    }

    func showDebateStatus(_ badge: DebateBadge) { self.badge = badge }
    func endDebate() { ended = true }

    /// The moderator pressing Send.
    func send() {
        sentCount += 1
        onPromptSent?()
    }

    /// This seat's debater answered, and the answer finished being read out.
    func answer(_ text: String) {
        pane = ""
        onStatementCompleted?(text)
    }
}

@MainActor
@Suite("Debate coordinator — two seats, one motion, handover by Send")
struct DebateCoordinatorTests {

    private func makeRoom(maxStatements: Int = 10) -> DebateRoom {
        DebateRoom(id: "owl-42",
                   motion: "AI should write its own tests",
                   seats: [DebateSeat(key: "for", name: "For the motion", position: "yes"),
                           DebateSeat(key: "against", name: "Against the motion", position: "no")],
                   maxStatements: maxStatements)
    }

    private func seated(_ coordinator: DebateCoordinator) -> (FakeParticipant, FakeParticipant) {
        let a = FakeParticipant("for")
        let b = FakeParticipant("against")
        coordinator.seat(a)
        coordinator.seat(b)
        return (a, b)
    }

    @Test("the opening prompt waits in the first seat's pane until Send")
    func openingWaitsForSend() {
        let coordinator = DebateCoordinator(room: makeRoom())
        let (a, b) = seated(coordinator)

        #expect(a.pane.contains("You open the debate"))
        #expect(a.sentCount == 0, "nothing is sent for you")
        #expect(b.pane.isEmpty)
        #expect(a.badge?.awaitingSend == true)
        #expect(b.badge?.awaitingSend == false)
        #expect(a.badge?.seatName == "For the motion")
        #expect(b.badge?.notice.contains("press Send") == true, "both bars tell the same story")
    }

    @Test("a statement read out in one window lands in the other, un-sent")
    func statementCrossesOver() {
        let coordinator = DebateCoordinator(room: makeRoom())
        let (a, b) = seated(coordinator)

        a.send()
        a.answer("For here. Tests are code, and code is our job.")

        #expect(b.pane.contains("For here. Tests are code, and code is our job."))
        #expect(b.sentCount == 0)
        #expect(b.badge?.awaitingSend == true)
        #expect(a.badge?.awaitingSend == false)

        b.send()
        b.answer("Against here. A test nobody read is not a test.")
        #expect(a.pane.contains("A test nobody read is not a test."))
        #expect(a.badge?.statementCount == 2)
    }

    @Test("a seat only speaks once its own prompt has been sent")
    func ignoresAnswersOutOfTurn() {
        let coordinator = DebateCoordinator(room: makeRoom())
        let (a, b) = seated(coordinator)

        b.answer("barging in")
        #expect(a.pane.contains("You open the debate"), "the opening prompt is untouched")
        #expect(a.badge?.statementCount == 0)
    }

    @Test("the budget is followed by a closing statement each, then both seats end")
    func endsAfterClosings() {
        let coordinator = DebateCoordinator(room: makeRoom(maxStatements: 2))
        let (a, b) = seated(coordinator)

        var speaker = a, listener = b
        var closings = 0
        for i in 1...4 where !coordinator.isOver {
            speaker.send()
            if speaker.pane.contains("final exchange") { closings += 1 }
            speaker.answer("statement \(i)")
            swap(&speaker, &listener)
        }

        #expect(closings == 2)
        #expect(coordinator.isOver)
        #expect(a.ended)
        #expect(b.ended)
        #expect(a.badge?.isOver == true)
    }

    @Test("one window closing ends the other, once")
    func closingOneEndsBoth() {
        let coordinator = DebateCoordinator(room: makeRoom())
        let (a, b) = seated(coordinator)
        var finished: [String] = []
        coordinator.onFinished = { finished.append($0) }

        // Ending B calls endDebate() on A; A reporting that back must not
        // start another round of endings.
        a.onSessionEnded = { [weak a] in a?.ended = true }
        b.onSessionEnded?()

        #expect(a.ended)
        #expect(coordinator.isOver)
        #expect(finished == ["owl-42"], "the registry is told exactly once")
    }

    @Test("a half-seated debate waits rather than starting")
    func waitsForTheSecondSeat() {
        let coordinator = DebateCoordinator(room: makeRoom())
        let a = FakeParticipant("for")
        coordinator.seat(a)

        #expect(a.pane.isEmpty)
        #expect(coordinator.filledSeats == 1)
        #expect(coordinator.freeSeats.map(\.key) == ["against"])
        #expect(a.badge?.notice.contains("Waiting") == true)
    }

    @Test("Skip turn offers the last statement again")
    func skipTurn() {
        let coordinator = DebateCoordinator(room: makeRoom())
        let (a, b) = seated(coordinator)
        a.send()
        a.answer("my point stands")
        b.pane = ""

        coordinator.skipTurn()
        #expect(b.pane.contains("my point stands"))
        #expect(b.badge?.notice.contains("No answer") == true,
                "the bar says why the statement came round again")
    }
}

@MainActor
@Suite("Debate window placement and voices")
struct DebatePresentationTests {

    @Test("a wide screen puts the two windows side by side")
    func sideBySide() {
        let screen = NSRect(x: 0, y: 0, width: 3000, height: 1600)
        let frames = DebateLayout.frames(seatCount: 2, in: screen)
        #expect(frames.count == 2)
        #expect(frames[0].minX == 0)
        #expect(frames[1].minX > frames[0].maxX - 1, "no overlap")
        #expect(frames[0].width >= Metrics.minWindowSize.width)
        #expect(frames[0].minY == frames[1].minY)
    }

    @Test("a laptop screen stacks them instead of squeezing the panes")
    func stacked() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frames = DebateLayout.frames(seatCount: 2, in: screen)
        #expect(frames[0].width == 1440, "full width keeps both panes usable")
        #expect(frames[0].minY > frames[1].minY, "seat one sits on top")
        #expect(frames[0].intersects(frames[1]) == false)
    }

    @Test("each seat gets a different voice")
    func distinctVoices() {
        let seats = [DebateSeat(key: "for", name: "For", position: "yes"),
                     DebateSeat(key: "against", name: "Against", position: "no")]
        let available = [(name: "Alex", identifier: "voice.alex"),
                         (name: "Samantha", identifier: "voice.samantha")]
        let deliveries = DebateVoices.deliveries(for: seats, available: available)
        #expect(deliveries.count == 2)
        #expect(deliveries[0].voiceIdentifier != deliveries[1].voiceIdentifier)
    }

    @Test("a seat's chosen voice is honoured, by name or identifier")
    func honoursTheChosenVoice() {
        let seats = [DebateSeat(key: "for", name: "For", position: "yes", voice: "Samantha"),
                     DebateSeat(key: "against", name: "Against", position: "no")]
        let available = [(name: "Alex", identifier: "voice.alex"),
                         (name: "Samantha", identifier: "voice.samantha")]
        let deliveries = DebateVoices.deliveries(for: seats, available: available)
        #expect(deliveries[0].voiceIdentifier == "voice.samantha")
        #expect(deliveries[1].voiceIdentifier == "voice.alex")
    }

    @Test("one installed voice still tells the sides apart, by pitch and rate")
    func fallsBackToPitch() {
        let seats = [DebateSeat(key: "for", name: "For", position: "yes"),
                     DebateSeat(key: "against", name: "Against", position: "no")]
        let deliveries = DebateVoices.deliveries(for: seats,
                                                 available: [(name: "Alex", identifier: "voice.alex")])
        #expect(deliveries[0].pitch != deliveries[1].pitch)
        #expect(deliveries[0].rate != deliveries[1].rate)
    }
}

@MainActor
@Suite("Taking a seat — what a client is told when it cannot")
struct DebateRegistryTests {

    private func room() -> DebateRoom {
        DebateRoom(id: "owl-42", motion: "a motion",
                   seats: [DebateSeat(key: "for", name: "For", position: "yes"),
                           DebateSeat(key: "against", name: "Against", position: "no")])
    }

    private func registry(_ room: DebateRoom) -> DebateRegistry {
        let registry = DebateRegistry()
        registry.create(room)
        return registry
    }

    @Test("an unknown debate names the menu bar, so the model can say what to do")
    func unknownRoom() {
        let registry = DebateRegistry()
        #expect(throws: VCPError.self) {
            try registry.seat(FakeParticipant("for"), join: DebateJoin(roomID: "nope-1", seat: "for"))
        }
        do {
            try registry.seat(FakeParticipant("for"), join: DebateJoin(roomID: "nope-1", seat: "for"))
        } catch let error as VCPError {
            #expect(error.actionableSentence.contains("no debate with id"))
            #expect(error.actionableSentence.contains("menu bar"))
        } catch {
            Issue.record("expected a VCPError")
        }
    }

    @Test("a taken seat points the client at the free one")
    func takenSeat() {
        let registry = registry(room())
        try? registry.seat(FakeParticipant("for"), join: DebateJoin(roomID: "owl-42", seat: "for"))

        do {
            try registry.seat(FakeParticipant("for"), join: DebateJoin(roomID: "owl-42", seat: "for"))
            Issue.record("the seat was already taken")
        } catch let error as VCPError {
            #expect(error.actionableSentence.contains("already taken"))
            #expect(error.actionableSentence.contains("\"against\""))
        } catch {
            Issue.record("expected a VCPError")
        }
    }

    @Test("a seat that does not exist lists the ones that do")
    func unknownSeat() {
        let registry = registry(room())
        do {
            try registry.seat(FakeParticipant("middle"), join: DebateJoin(roomID: "owl-42", seat: "middle"))
            Issue.record("there is no such seat")
        } catch let error as VCPError {
            #expect(error.actionableSentence.contains("\"for\" and \"against\""))
        } catch {
            Issue.record("expected a VCPError")
        }
    }

    @Test("a finished debate is forgotten, so its id stops working")
    func finishedRoomIsForgotten() {
        let registry = registry(room())
        try? registry.seat(FakeParticipant("for"), join: DebateJoin(roomID: "owl-42", seat: "for"))
        try? registry.seat(FakeParticipant("against"), join: DebateJoin(roomID: "owl-42", seat: "against"))
        #expect(registry.rooms.count == 1)

        registry.coordinator("owl-42")?.endDebate()
        #expect(registry.rooms.isEmpty)
    }
}
