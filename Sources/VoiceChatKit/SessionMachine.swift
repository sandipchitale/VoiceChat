import Foundation

// Spec §5 — Session and turn state machine.
//
// This type is the single authority for every enable/disable, every microphone
// transition and every window change (§5 preamble). UI state is *derived* from
// it; nothing sets a control directly.

// MARK: - Vocabulary

public enum VoiceMode: String, Sendable, Equatable, CaseIterable {
    case dictation
    case command
}

public enum EndReason: String, Sendable, Codable, Equatable {
    case userEnded = "user_ended"
    case windowClosed = "window_closed"
    case hostCancelled = "host_cancelled"
    case daemonQuit = "daemon_quit"
    case mcpExit = "mcp_exit"
    case peerLost = "peer_lost"
}

public enum SessionState: Sendable, Equatable {
    case idle
    case composing
    case submitted
    case respondingAuto
    case respondingManual
    case ended(EndReason)

    /// §5.1 — the two `Responding` states differ only in what happens when
    /// speech finishes (R-FSM-1).
    public var isResponding: Bool {
        self == .respondingAuto || self == .respondingManual
    }

    public var isTerminal: Bool {
        if case .ended = self { return true }
        return false
    }
}

public enum SessionEvent: Sendable, Equatable {
    case sessionOpened
    case send(isEmpty: Bool)
    case setVoiceMode(VoiceMode)
    case setMicEnabled(Bool)
    case responseReceived(isEmpty: Bool)
    case speechFinished
    case speechCancelled
    case stop
    case play
    case gotIt
    case end(EndReason)
}

// MARK: - Effects

public enum RecognizerAction: Sendable, Equatable {
    case unchanged
    case stop
    case start(VoiceMode)
}

public enum SpeechAction: Sendable, Equatable {
    case unchanged
    case stop
    case start
}

/// The effect columns of the §5.2 transition table, made explicit so tests can
/// assert them one by one rather than inferring them from the resulting state.
public struct SessionEffects: Sendable, Equatable {
    public var recognizer: RecognizerAction = .unchanged
    public var speech: SpeechAction = .unchanged
    public var advancesTurn = false
    public var commitsTurnToHistory = false
    public var clearsPanes = false
    /// R-UI-7 — Send with an empty pane is rejected, not submitted.
    public var rejectsEmptySend = false
    public var submitsPrompt = false
    public var closesSession: EndReason?

    public static let none = SessionEffects()
}

/// The outcome of one event. `row` is the §5.2 row number, logged at `info`
/// so a desync report can be reconstructed from a log alone (R-LOG-5).
public struct SessionTransition: Sendable, Equatable {
    public let row: Int?
    public let from: SessionState
    public let to: SessionState
    public let effects: SessionEffects

    /// True when the event produced no transition and no effects.
    public var isIgnored: Bool { row == nil }
}

// MARK: - The machine

public struct SessionMachine: Sendable, Equatable {
    public private(set) var state: SessionState = .idle
    public private(set) var turn: Int = 0
    public private(set) var voiceMode: VoiceMode = .dictation
    public private(set) var isSpeaking = false

    /// Whether the person has the microphone switched on. Independent of
    /// whether the recogniser is *allowed* to run in the current state.
    public var micEnabled = true

    /// R-UI-24 — forced off under VoiceOver. With auto-play off, row 6 enters
    /// `respondingManual` directly.
    public var autoPlayEnabled = true

    public init() {}

    // MARK: Derived state

    /// R-FSM-4 — the recogniser runs iff `composing` with the mic enabled, or
    /// `respondingManual` with nothing being spoken.
    public var recognizerShouldRun: Bool {
        guard micEnabled else { return false }
        switch state {
        case .composing: return true
        case .respondingManual: return !isSpeaking
        default: return false
        }
    }

    /// R-FSM-6 — which pane holds first responder.
    public enum Pane: Sendable, Equatable { case prompt, response }
    public var focusedPane: Pane {
        state.isResponding ? .response : .prompt
    }

    // MARK: Reducer

    @discardableResult
    public mutating func handle(_ event: SessionEvent) -> SessionTransition {
        let from = state

        // R-FSM-8 — `ended` is terminal. Every event is ignored.
        guard !state.isTerminal else {
            return SessionTransition(row: nil, from: from, to: from, effects: .none)
        }

        // Rows 14/15/16 — any non-terminal state may be ended.
        if case .end(let reason) = event {
            isSpeaking = false
            state = .ended(reason)
            var fx = SessionEffects()
            fx.recognizer = .stop
            fx.speech = .stop
            fx.closesSession = reason
            return SessionTransition(row: row(for: reason), from: from, to: state, effects: fx)
        }

        switch (state, event) {

        // Row 1
        case (.idle, .sessionOpened):
            turn = 1
            voiceMode = .dictation
            state = .composing
            var fx = SessionEffects()
            fx.recognizer = micEnabled ? .start(.dictation) : .stop
            return t(1, from, fx)

        // Row 3 — empty send is rejected before row 2 can match.
        case (.composing, .send(let isEmpty)) where isEmpty:
            var fx = SessionEffects()
            fx.rejectsEmptySend = true
            return t(3, from, fx)

        // Row 2
        case (.composing, .send):
            state = .submitted
            var fx = SessionEffects()
            fx.recognizer = .stop
            fx.submitsPrompt = true
            return t(2, from, fx)

        // Row 4 — mode switch, from the control or from a spoken phrase.
        case (.composing, .setVoiceMode(let mode)),
             (.respondingManual, .setVoiceMode(let mode)):
            guard mode != voiceMode else { return ignored(from) }
            voiceMode = mode
            var fx = SessionEffects()
            fx.recognizer = recognizerShouldRun ? .start(mode) : .unchanged
            return t(4, from, fx)

        // Row 5
        case (.composing, .setMicEnabled(let on)):
            guard on != micEnabled else { return ignored(from) }
            micEnabled = on
            var fx = SessionEffects()
            fx.recognizer = on ? .start(voiceMode) : .stop
            return t(5, from, fx)

        // Row 7 — empty response never enters a `Responding` state (§5.4).
        case (.submitted, .responseReceived(let isEmpty)) where isEmpty:
            return advanceTurn(row: 7, from: from, stopSpeech: false)

        // Row 6
        case (.submitted, .responseReceived):
            var fx = SessionEffects()
            fx.recognizer = .stop
            if autoPlayEnabled {
                state = .respondingAuto
                isSpeaking = true
                fx.speech = .start
                return t(6, from, fx)
            } else {
                // R-UI-24 — no auto-play: land in manual, ready for Play.
                state = .respondingManual
                isSpeaking = false
                fx.recognizer = micEnabled ? .start(.command) : .stop
                voiceMode = .command
                return t(6, from, fx)
            }

        // Row 8 — finishing naturally in Auto advances the turn.
        case (.respondingAuto, .speechFinished):
            isSpeaking = false
            return advanceTurn(row: 8, from: from, stopSpeech: false)

        // Row 9 — Stop latches the turn into Manual, permanently (R-TTS-12).
        case (.respondingAuto, .stop), (.respondingAuto, .speechCancelled):
            state = .respondingManual
            isSpeaking = false
            voiceMode = .command
            var fx = SessionEffects()
            fx.speech = .stop
            fx.recognizer = micEnabled ? .start(.command) : .stop
            return t(9, from, fx)

        // Row 10
        case (.respondingManual, .play):
            guard !isSpeaking else { return ignored(from) }
            isSpeaking = true
            var fx = SessionEffects()
            fx.recognizer = .stop
            fx.speech = .start
            return t(10, from, fx)

        // Row 11 — finishing in Manual does *not* advance (R-TTS-13).
        case (.respondingManual, .speechFinished):
            guard isSpeaking else { return ignored(from) }
            isSpeaking = false
            voiceMode = .command
            var fx = SessionEffects()
            fx.recognizer = micEnabled ? .start(.command) : .stop
            return t(11, from, fx)

        // Row 12
        case (.respondingManual, .stop), (.respondingManual, .speechCancelled):
            guard isSpeaking else { return ignored(from) }
            isSpeaking = false
            voiceMode = .command
            var fx = SessionEffects()
            fx.speech = .stop
            fx.recognizer = micEnabled ? .start(.command) : .stop
            return t(12, from, fx)

        // Row 13 — the only way out of Manual (R-TTS-14).
        case (.respondingAuto, .gotIt), (.respondingManual, .gotIt):
            isSpeaking = false
            return advanceTurn(row: 13, from: from, stopSpeech: true)

        // Mic toggling is inert wherever the recogniser is not allowed to run.
        case (_, .setMicEnabled(let on)):
            guard on != micEnabled else { return ignored(from) }
            micEnabled = on
            return ignored(from)

        default:
            return ignored(from)
        }
    }

    // MARK: Helpers

    /// Rows 7, 8 and 13 — the only transitions that advance the turn (R-FSM-7),
    /// and the only ones that commit a turn to history and clear the panes
    /// (R-FSM-9).
    private mutating func advanceTurn(row: Int, from: SessionState, stopSpeech: Bool) -> SessionTransition {
        turn += 1
        voiceMode = .dictation
        state = .composing
        var fx = SessionEffects()
        fx.advancesTurn = true
        fx.commitsTurnToHistory = true
        fx.clearsPanes = true
        fx.speech = stopSpeech ? .stop : .unchanged
        fx.recognizer = micEnabled ? .start(.dictation) : .stop
        return t(row, from, fx)
    }

    private func t(_ row: Int, _ from: SessionState, _ fx: SessionEffects) -> SessionTransition {
        SessionTransition(row: row, from: from, to: state, effects: fx)
    }

    private func ignored(_ from: SessionState) -> SessionTransition {
        SessionTransition(row: nil, from: from, to: state, effects: .none)
    }

    private func row(for reason: EndReason) -> Int {
        switch reason {
        case .userEnded, .windowClosed: return 14
        case .hostCancelled, .daemonQuit, .mcpExit: return 15
        case .peerLost: return 16
        }
    }
}
