import Foundation

// The debate's rules, as a reducer — the same shape as `SessionMachine`, and
// for the same reason: whose turn it is must be decidable without a window, a
// synthesiser or a network, so it can be tested one event at a time.
//
// The machine never sends anything itself. It returns effects; the coordinator
// carries them out.

public enum DebatePhase: Sendable, Equatable {
    /// Not every seat is taken yet.
    case awaitingSeats
    /// A statement is sitting in this seat's prompt pane, waiting for Send.
    case awaitingSend(seat: String)
    /// This seat has the floor; its debater is answering.
    case awaitingStatement(seat: String)
    /// Closing arguments.
    case closing(seat: String)
    case ended
}

public enum DebateEffect: Sendable, Equatable {
    /// Put `text` in this seat's prompt pane; send it only if `autoSend`.
    case deliver(seat: String, text: String, autoSend: Bool)
    /// Say something in every seat's debate bar.
    case notice(String)
    case endAll
}

public enum DebateEvent: Sendable, Equatable {
    case seatFilled(String)
    /// A seat's statement finished being read out.
    case statementCompleted(seat: String, text: String)
    /// The moderator pressed Send in this seat's window.
    case promptSent(seat: String)
    /// The moderator gave up on the seat that has the floor.
    case skipTurn
    case seatEnded(seat: String)
    case endRequested
}

public struct DebateMachine: Sendable, Equatable {
    public let room: DebateRoom
    public private(set) var phase: DebatePhase = .awaitingSeats
    /// Statements read out so far, closings excluded.
    public private(set) var statementCount = 0
    /// Seats that have been told the rules.
    private var briefed: Set<String> = []
    private var filled: Set<String> = []
    private struct Statement: Sendable, Equatable {
        var seat: String
        var text: String
    }
    private var lastStatement: Statement?
    private var closingsLeft = 0

    public init(room: DebateRoom) {
        self.room = room
    }

    public var isRunning: Bool { phase != .awaitingSeats && phase != .ended }
    public var filledSeats: Int { filled.count }

    /// The seat whose window is currently the one to watch, if any.
    public var activeSeat: String? {
        switch phase {
        case .awaitingSend(let seat), .awaitingStatement(let seat), .closing(let seat): return seat
        case .awaitingSeats, .ended: return nil
        }
    }

    /// The seat that actually has the floor — one whose prompt has been sent
    /// and whose answer is awaited. A seat with a statement still sitting
    /// un-sent in its pane does not have the floor yet.
    private var seatWithFloor: String? {
        switch phase {
        case .awaitingStatement(let seat), .closing(let seat): return seat
        case .awaitingSeats, .awaitingSend, .ended: return nil
        }
    }

    @discardableResult
    public mutating func handle(_ event: DebateEvent) -> [DebateEffect] {
        guard phase != .ended else { return [] }

        switch event {

        case .seatFilled(let key):
            guard room.seat(key) != nil else { return [] }
            filled.insert(key)
            guard filled.count == room.seats.count, let opener = room.openingSeat else {
                return [.notice("Waiting for the other seat…")]
            }
            briefed.insert(opener.key)
            phase = .awaitingSend(seat: opener.key)
            return [.notice("\(opener.name) opens — press Send"),
                    .deliver(seat: opener.key, text: room.openingPrompt(for: opener), autoSend: false)]

        case .promptSent(let key):
            guard case .awaitingSend(let expected) = phase, expected == key else { return [] }
            phase = closingsLeft > 0 ? .closing(seat: key) : .awaitingStatement(seat: key)
            return []

        case .statementCompleted(let key, let text):
            guard seatWithFloor == key else { return [] }
            lastStatement = Statement(seat: key, text: text)

            if case .closing = phase {
                closingsLeft -= 1
                if closingsLeft <= 0 {
                    phase = .ended
                    return [.notice("The debate is over."), .endAll]
                }
                return hand(to: key, statement: text, closing: true)
            }

            statementCount += 1
            if statementCount >= room.maxStatements {
                // Never cut a debater off mid-thought: every seat gets a last
                // word before the room closes.
                closingsLeft = room.seats.count
                return hand(to: key, statement: text, closing: true)
            }
            return hand(to: key, statement: text, closing: false)

        case .skipTurn:
            guard let last = lastStatement else { return [] }
            // One notice, not two: the second would immediately replace the
            // first and the moderator would never see why the turn moved.
            return hand(to: last.seat, statement: last.text, closing: closingsLeft > 0)
                .map { effect in
                    guard case .notice(let text) = effect else { return effect }
                    return .notice("No answer — the statement was offered again. " + text)
                }

        case .seatEnded(let key):
            phase = .ended
            let name = room.seat(key)?.name ?? key
            return [.notice("\(name) left the debate."), .endAll]

        case .endRequested:
            phase = .ended
            return [.notice("The debate was ended."), .endAll]
        }
    }

    /// Passes `statement` from `speaker` to the next seat.
    private mutating func hand(to speaker: String, statement: String,
                               closing: Bool) -> [DebateEffect] {
        guard let from = room.seat(speaker), let to = room.seat(after: speaker) else { return [] }
        let first = briefed.insert(to.key).inserted
        let text = closing
            ? room.closingPrompt(statement, from: from, to: to)
            : room.relay(statement, from: from, to: to, includeBriefing: first)
        phase = .awaitingSend(seat: to.key)
        let what = closing ? "closing statement" : "statement \(statementCount + 1)"
        return [.notice("\(to.name): \(what) ready — press Send"),
                .deliver(seat: to.key, text: text, autoSend: false)]
    }
}
