import Foundation
import VoiceChatKit

// The live debate rooms. The person creates a room from the menu bar; MCP
// clients claim its seats by id, one client per seat.
//
// A refusal here is read by a model, so every message is a sentence it can act
// on rather than a code (the same rule VCP errors follow).

@MainActor
public final class DebateRegistry {
    public static let shared = DebateRegistry()

    private var coordinators: [String: DebateCoordinator] = [:]

    /// Fires whenever a room is created, seated or finished, so the menu bar
    /// can redraw.
    public var onRoomsChanged: (() -> Void)?

    init() {}

    public var rooms: [DebateRoom] {
        coordinators.values.map(\.room).sorted { $0.id < $1.id }
    }

    public func coordinator(_ roomID: String) -> DebateCoordinator? { coordinators[roomID] }

    @discardableResult
    public func create(_ room: DebateRoom) -> DebateCoordinator {
        let coordinator = DebateCoordinator(room: room)
        // Synchronous on purpose: the moment a debate ends its id must stop
        // working, so a client cannot take a seat in a room that is closing.
        coordinator.onFinished = { [weak self] id in
            self?.close(id)
        }
        coordinators[room.id] = coordinator
        onRoomsChanged?()
        return coordinator
    }

    public func close(_ roomID: String) {
        guard coordinators.removeValue(forKey: roomID) != nil else { return }
        onRoomsChanged?()
    }

    /// Seats `participant`, or throws a sentence saying why it could not.
    public func seat(_ participant: any DebateParticipant, join: DebateJoin) throws {
        guard let coordinator = coordinators[join.roomID] else {
            throw VCPError.debateSeatUnavailable(
                "There is no debate with id \"\(join.roomID)\". Ask the user to create one from the "
                + "VoiceChat menu bar, then tell you its id, and stop until they do.")
        }
        guard coordinator.room.seat(join.seat) != nil else {
            throw VCPError.debateSeatUnavailable(
                "Debate \"\(join.roomID)\" has no seat called \"\(join.seat)\". Its seats are "
                + list(coordinator.room.seats.map(\.key)) + ". Ask the user which one you should take.")
        }
        let free = coordinator.freeSeats.map(\.key)
        guard free.contains(join.seat) else {
            let alternative = free.isEmpty
                ? "Every seat is taken, so this debate is full."
                : "The free seat is " + list(free) + "."
            throw VCPError.debateSeatUnavailable(
                "The \"\(join.seat)\" seat in debate \"\(join.roomID)\" is already taken. "
                + alternative + " Tell the user and stop.")
        }
        coordinator.seat(participant)
        onRoomsChanged?()
    }

    private func list(_ items: [String]) -> String {
        let quoted = items.map { "\"\($0)\"" }
        guard let last = quoted.last else { return "none" }
        return quoted.count == 1 ? last : quoted.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Stands in for a seat just long enough to ask the registry whether it could
/// be taken. Seating it never succeeds — `DebateRegistry.seat` throws first,
/// with the sentence explaining why — so the daemon can decline a join without
/// having built a window for it.
@MainActor
final class RejectedSeat: DebateParticipant {
    let seatKey = ""
    func deliver(_ text: String, autoSend: Bool) {}
    func showDebateStatus(_ badge: DebateBadge) {}
    func endDebate() {}
    var onStatementCompleted: ((String) -> Void)?
    var onPromptSent: (() -> Void)?
    var onSessionEnded: (() -> Void)?
}
