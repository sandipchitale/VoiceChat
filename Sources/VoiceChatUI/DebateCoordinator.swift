import Foundation
import VoiceChatKit

// Carries `DebateMachine`'s effects to two real conversation windows.
//
// It talks to seats through `DebateParticipant`, never to `Session` directly,
// so the whole handover can be driven in a test with no window, no MCP peer
// and no synthesiser.

/// What the debate bar shows in one seat's window.
public struct DebateBadge: Sendable, Equatable {
    public var roomID: String
    public var motion: String
    public var seatName: String
    public var position: String
    public var statementCount: Int
    public var maxStatements: Int
    public var notice: String
    /// A statement is sitting in this window's prompt pane, waiting for Send.
    public var awaitingSend: Bool
    /// This seat hands over without waiting for Send.
    public var autoHandoff: Bool
    public var isOver: Bool

    public init(roomID: String, motion: String, seatName: String, position: String,
                statementCount: Int = 0, maxStatements: Int = 0, notice: String = "",
                awaitingSend: Bool = false, autoHandoff: Bool = false, isOver: Bool = false) {
        self.roomID = roomID
        self.motion = motion
        self.seatName = seatName
        self.position = position
        self.statementCount = statementCount
        self.maxStatements = maxStatements
        self.notice = notice
        self.awaitingSend = awaitingSend
        self.autoHandoff = autoHandoff
        self.isOver = isOver
    }
}

@MainActor
public protocol DebateParticipant: AnyObject {
    var seatKey: String { get }
    /// Put `text` in this seat's prompt pane, sending it only if asked.
    func deliver(_ text: String, autoSend: Bool)
    func showDebateStatus(_ badge: DebateBadge)
    func endDebate()

    /// A statement finished being read out in this window.
    var onStatementCompleted: ((String) -> Void)? { get set }
    /// The moderator pressed Send here.
    var onPromptSent: (() -> Void)? { get set }
    /// This window's conversation ended, however it ended.
    var onSessionEnded: (() -> Void)? { get set }

    /// Hands the seat the moderator's controls for its debate bar.
    func setModeratorActions(skip: @escaping () -> Void, end: @escaping () -> Void,
                             autoHandoff: @escaping (Bool) -> Void)

    /// The Talking Head character this seat reads with. Seats alternate, so
    /// the two sides never share one.
    func setTalkingHeadVoice(_ voice: TalkingHeadVoice)
    /// Wires this seat's voice picker: the moderator chose `voice` here.
    func onTalkingHeadVoiceChosen(_ chosen: @escaping (TalkingHeadVoice) -> Void)
}

public extension DebateParticipant {
    func setModeratorActions(skip: @escaping () -> Void, end: @escaping () -> Void,
                             autoHandoff: @escaping (Bool) -> Void) {}
    func setTalkingHeadVoice(_ voice: TalkingHeadVoice) {}
    func onTalkingHeadVoiceChosen(_ chosen: @escaping (TalkingHeadVoice) -> Void) {}
}

@MainActor
public final class DebateCoordinator {
    public let room: DebateRoom
    private var machine: DebateMachine
    private var participants: [String: any DebateParticipant] = [:]
    private var notice = ""
    /// Ending one seat ends the other, which reports *its* ending back: without
    /// this the two would chase each other round.
    private var isTearingDown = false
    /// The first seat's Talking Head character. Every other seat alternates
    /// from it. Kept here, not in the shared settings, so a debate never
    /// changes the voice ordinary conversations use.
    private var firstSeatVoice: TalkingHeadVoice

    /// The debate finished and the registry should forget it.
    public var onFinished: ((String) -> Void)?

    public init(room: DebateRoom, talkingHeadVoice: TalkingHeadVoice = .male) {
        self.room = room
        self.machine = DebateMachine(room: room)
        self.firstSeatVoice = talkingHeadVoice
    }

    public var filledSeats: Int { machine.filledSeats }
    public var isOver: Bool { machine.phase == .ended }
    public var freeSeats: [DebateSeat] {
        room.seats.filter { participants[$0.key] == nil }
    }

    // MARK: Seating

    public func seat(_ participant: any DebateParticipant) {
        let key = participant.seatKey
        guard room.seat(key) != nil, participants[key] == nil else { return }
        participants[key] = participant

        participant.onStatementCompleted = { [weak self] text in
            self?.apply(.statementCompleted(seat: key, text: text))
        }
        participant.onPromptSent = { [weak self] in
            self?.apply(.promptSent(seat: key))
        }
        participant.onSessionEnded = { [weak self] in
            guard let self, !self.isTearingDown else { return }
            self.apply(.seatEnded(seat: key))
        }

        participant.setModeratorActions(
            skip: { [weak self] in self?.skipTurn() },
            end: { [weak self] in self?.endDebate() },
            autoHandoff: { [weak self] on in self?.setAutoHandoff(key, on) })
        participant.onTalkingHeadVoiceChosen { [weak self] voice in
            self?.chooseTalkingHeadVoice(voice, forSeat: key)
        }
        participant.setTalkingHeadVoice(talkingHeadVoice(forSeat: key))

        apply(.seatFilled(key))
    }

    // MARK: Moderator actions

    public func skipTurn() { apply(.skipTurn) }
    public func endDebate() { apply(.endRequested) }
    public func setAutoHandoff(_ seat: String, _ on: Bool) {
        apply(.setAutoHandoff(seat: seat, on: on))
    }

    // MARK: Talking Head voices

    /// Even seats take the first seat's character, odd seats the other one.
    public func talkingHeadVoice(forSeat key: String) -> TalkingHeadVoice {
        let index = room.seats.firstIndex { $0.key == key } ?? 0
        return index.isMultiple(of: 2) ? firstSeatVoice : firstSeatVoice.opposite
    }

    /// A seat's picker changed: that seat gets `voice`, and every other seat
    /// is flipped so the sides stay opposite.
    public func chooseTalkingHeadVoice(_ voice: TalkingHeadVoice, forSeat key: String) {
        let index = room.seats.firstIndex { $0.key == key } ?? 0
        firstSeatVoice = index.isMultiple(of: 2) ? voice : voice.opposite
        for (seat, participant) in participants {
            participant.setTalkingHeadVoice(talkingHeadVoice(forSeat: seat))
        }
    }

    // MARK: Effects

    private func apply(_ event: DebateEvent) {
        let effects = machine.handle(event)
        for effect in effects {
            switch effect {
            case .deliver(let seat, let text, let autoSend):
                participants[seat]?.deliver(text, autoSend: autoSend)
            case .notice(let text):
                notice = text
            case .endAll:
                isTearingDown = true
                for participant in participants.values { participant.endDebate() }
                onFinished?(room.id)
            }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        for (key, participant) in participants {
            guard let seat = room.seat(key) else { continue }
            participant.showDebateStatus(DebateBadge(
                roomID: room.id,
                motion: room.motion,
                seatName: seat.name,
                position: seat.position,
                statementCount: machine.statementCount,
                maxStatements: room.maxStatements,
                notice: notice,
                awaitingSend: machine.phase == .awaitingSend(seat: key),
                autoHandoff: machine.isAutoHandoff(key),
                isOver: machine.phase == .ended))
        }
    }
}
