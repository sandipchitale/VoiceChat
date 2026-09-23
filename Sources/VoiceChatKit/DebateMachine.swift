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
    /// The moderator switched automatic handover on or off for one seat.
    case setAutoHandoff(seat: String, on: Bool)
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
    /// Seats whose moderator asked for automatic handover.
    private var autoSeats: Set<String> = []
    /// What is sitting un-sent in a seat's prompt pane, so switching automatic
    /// handover on can pass along the statement already waiting.
    private var pendingDelivery: Statement?

    public func isAutoHandoff(_ seat: String) -> Bool { autoSeats.contains(seat) }

    public init(room: DebateRoom) {
        self.room = room
    }

    public var filledSeats: Int { filled.count }

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
            return deliver(room.openingPrompt(for: opener), to: opener,
                           notice: "\(opener.name) opens")

        case .setAutoHandoff(let key, let on):
            guard room.seat(key) != nil else { return [] }
            if on { autoSeats.insert(key) } else { autoSeats.remove(key) }
            // Switching it on with a statement already waiting passes that one
            // along too, rather than stranding it until the next handover.
            guard on, let pending = pendingDelivery, pending.seat == key,
                  let seat = room.seat(key) else { return [] }
            return deliver(pending.text, to: seat, notice: "\(seat.name) is handing over automatically")

        case .promptSent(let key):
            guard case .awaitingSend(let expected) = phase, expected == key else { return [] }
            pendingDelivery = nil
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
        let what = closing ? "closing statement" : "statement \(statementCount + 1)"
        return deliver(text, to: to, notice: "\(to.name): \(what)")
    }

    /// Hands `text` to a seat: it waits in that window's prompt pane unless
    /// the moderator asked this seat to hand over automatically.
    private mutating func deliver(_ text: String, to seat: DebateSeat,
                                  notice: String) -> [DebateEffect] {
        let auto = autoSeats.contains(seat.key)
        phase = .awaitingSend(seat: seat.key)
        pendingDelivery = Statement(seat: seat.key, text: text)
        return [.notice(auto ? notice : notice + " — press Send"),
                .deliver(seat: seat.key, text: text, autoSend: auto)]
    }
}
