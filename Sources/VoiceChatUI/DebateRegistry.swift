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
        // The first seat starts from the voice ordinary conversations use,
        // and the other side takes the opposite.
        let coordinator = DebateCoordinator(room: room,
                                            talkingHeadVoice: GlassSettings.shared.talkingHeadVoice)
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

    /// A claim on a free seat, checked before anything is built for it.
    public struct Reservation: Sendable {
        public let roomID: String
        public let seat: DebateSeat
        /// Where this seat sits among the room's seats — its window's place.
        public let index: Int
        public let seatCount: Int
    }

    /// Checks a claim and says what it is for, or throws a sentence saying why
    /// it cannot be honoured. Nothing is built or attached here, so a refusal
    /// costs no window.
    public func reserve(_ join: DebateJoin) throws -> Reservation {
        guard let coordinator = coordinators[join.roomID] else {
            throw VCPError.debateSeatUnavailable(
                "There is no debate with id \"\(join.roomID)\". Ask the user to create one from the "
                + "VoiceChat menu bar, then tell you its id, and stop until they do.")
        }
        guard let index = coordinator.room.seats.firstIndex(where: { $0.key == join.seat }) else {
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
        return Reservation(roomID: join.roomID, seat: coordinator.room.seats[index],
                           index: index, seatCount: coordinator.room.seats.count)
    }

    /// Takes a reserved seat.
    public func take(_ reservation: Reservation, with participant: any DebateParticipant) {
        coordinators[reservation.roomID]?.seat(participant)
        onRoomsChanged?()
    }

    /// Reserves and takes in one step — the path a test or a caller with
    /// nothing to build takes.
    public func seat(_ participant: any DebateParticipant, join: DebateJoin) throws {
        take(try reserve(join), with: participant)
    }

    private func list(_ items: [String]) -> String {
        let quoted = items.map { "\"\($0)\"" }
        guard let last = quoted.last else { return "none" }
        return quoted.count == 1 ? last : quoted.dropLast().joined(separator: ", ") + " and " + last
    }
}
