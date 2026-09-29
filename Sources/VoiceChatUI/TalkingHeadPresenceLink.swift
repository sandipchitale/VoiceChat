import Foundation
import VoiceChatKit

// Spec §9.5 — one window's presence on Talking Head's face (R-TTS-17 … R-TTS-21).

/// Tells Talking Head what this window's face should show between readings:
/// listening while the person composes, thinking while the model works. It
/// holds one long-lived spooler connection while there is anything to show,
/// kept (with `none`) through the responding states, and closed when the
/// conversation ends, Talking Head is turned off or muted, or the window
/// closes. Closing lets Talking Head drop the presence, and the face goes.
///
/// A Talking Head that doesn't acknowledge presence (an older one, or none
/// at all) gets nothing more from this link: replies are read as before.
@MainActor
final class TalkingHeadPresenceLink {
    private let socketPath: String
    private var sequencer = PresenceSequencer()
    private var throttle = NodThrottle()
    private var connection: TalkingHeadSpoolerConnection?
    /// The voice last sent, so a changed seat voice is sent even when the
    /// presence itself is unchanged.
    private var sentVoice: TalkingHeadVoice?
    private var acknowledged = false
    /// Talking Head didn't acknowledge presence: stay out of its way.
    private(set) var isUnsupported = false
    /// Counts connections, so a late reply from a closed one is ignored.
    private var generation = 0

    /// What went out, for tests: "listening male", "nod", "close".
    private(set) var log: [String] = []

    init(socketPath: String = TalkingHeadSpooler.socketPath) {
        self.socketPath = socketPath
    }

    /// The single entry point: called after every state-machine transition,
    /// and whenever mute, the Talking Head toggle or the voice changes.
    func update(machine: SessionMachine, talkingHeadOn: Bool, muted: Bool, voice: TalkingHeadVoice) {
        guard !isUnsupported else { return }
        let presence = TalkingHeadPresence.for(state: machine.state, isSpeaking: machine.isSpeaking,
                                               talkingHeadOn: talkingHeadOn, muted: muted)
        // Nothing to show until the next turn starts, or ever again: let go.
        let holds: Bool
        switch machine.state {
        case .idle, .ended: holds = false
        default: holds = talkingHeadOn && !muted
        }
        guard holds else {
            close()
            return
        }
        let changed = sequencer.next(presence)
        let voiceChanged = presence != .none && voice != sentVoice
        guard changed != nil || voiceChanged else { return }
        // Nothing to clear on a connection that was never opened.
        if presence == .none, connection == nil { return }
        send(.presence(presence, voice: voice.rawValue), described: "\(presence.rawValue) \(voice.rawValue)")
        sentVoice = voice
    }

    /// `R-TTS-18` — a phrase was finalised while composing: a nod, at most one
    /// per 600 ms, and only while the face is listening.
    func nod(voice: TalkingHeadVoice) {
        guard !isUnsupported, connection != nil, acknowledged, sequencer.last == .listening,
              throttle.shouldNod(at: Date()) else { return }
        send(.presence(.listening, voice: voice.rawValue, nod: true), described: "nod")
    }

    /// Lets the face go: the conversation ended, Talking Head was turned off
    /// or muted, or the window closed.
    func close() {
        sequencer.reset()
        sentVoice = nil
        guard let connection else { return }
        connection.close()
        self.connection = nil
        generation += 1
        log.append("close")
    }

    // MARK: Connection

    private func send(_ request: TalkingHeadSpoolerRequest, described: String) {
        if connection == nil, !open() { return }
        guard connection?.send(request) == true else {
            // Talking Head quit: start afresh on the next change.
            dropConnection()
            return
        }
        log.append(described)
    }

    private func open() -> Bool {
        guard let connection = TalkingHeadSpoolerConnection.open(at: socketPath) else {
            // No Talking Head running: presence waits for the next change.
            sequencer.reset()
            return false
        }
        self.connection = connection
        acknowledged = false
        generation += 1
        let id = generation
        Task.detached { [weak self] in
            while let event = connection.nextEvent() {
                await self?.received(event, generation: id)
            }
            await self?.ended(generation: id)
        }
        // R-TTS-19 — an answer is due within 300 ms.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TalkingHeadSpooler.replyTimeout))
            guard let self, id == self.generation, !self.acknowledged else { return }
            self.giveUp()
        }
        return true
    }

    private func received(_ event: TalkingHeadSpoolerEvent, generation id: Int) {
        guard id == generation else { return }
        switch event.kind {
        case .presence: acknowledged = true
        // An older Talking Head doesn't know presence: it says so once.
        case .error: giveUp()
        default: break
        }
    }

    private func ended(generation id: Int) {
        guard id == generation else { return }
        dropConnection()
    }

    private func giveUp() {
        isUnsupported = true
        close()
    }

    private func dropConnection() {
        connection?.close()
        connection = nil
        generation += 1
        sequencer.reset()
        sentVoice = nil
    }
}
