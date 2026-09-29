import Foundation

// Spec §9.5 — Talking Head's face follows the session state machine (§5):
// listening while the person composes, thinking while the model works, and
// nothing of its own while a reply is read (the reading is the face then).

/// What Talking Head's face shows between readings, as sent on its spooler
/// socket (`TalkingHeadSpooler`).
public enum TalkingHeadPresence: String, Sendable, Equatable, CaseIterable {
    case listening, thinking, none

    /// `R-TTS-17` — the presence for a session state. The state machine is the
    /// single source: nothing else decides what the face shows.
    public static func `for`(state: SessionState, isSpeaking: Bool,
                             talkingHeadOn: Bool, muted: Bool) -> TalkingHeadPresence {
        guard talkingHeadOn, !muted else { return .none }
        switch state {
        case .idle, .ended:     return .none
        case .composing:        return .listening
        case .submitted:        return .thinking
        case .respondingAuto:   return .none
        case .respondingManual: return isSpeaking ? .none : .listening
        }
    }
}

/// Passes a presence on only when it differs from the last one passed on, so
/// the face is told about changes, not about every transition.
public struct PresenceSequencer: Sendable, Equatable {
    /// What the face was last told. It starts out showing nothing.
    public private(set) var last: TalkingHeadPresence = .none

    public init() {}

    /// The presence to send, or nil when it is what was last sent.
    public mutating func next(_ presence: TalkingHeadPresence) -> TalkingHeadPresence? {
        guard presence != last else { return nil }
        last = presence
        return presence
    }

    /// The face was let go (its connection closed): it shows nothing again.
    public mutating func reset() { last = .none }
}

/// `R-TTS-18` — at most one nod per `interval`, however fast phrases are
/// finalised.
public struct NodThrottle: Sendable, Equatable {
    public let interval: TimeInterval
    private var lastNod: Date?

    public init(interval: TimeInterval = 0.6) { self.interval = interval }

    /// Whether a phrase finalised at `now` gets a nod (and, if so, records it).
    public mutating func shouldNod(at now: Date) -> Bool {
        if let lastNod, now.timeIntervalSince(lastNod) < interval { return false }
        lastNod = now
        return true
    }
}
