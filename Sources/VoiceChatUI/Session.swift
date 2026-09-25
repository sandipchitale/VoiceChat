import AppKit
import Foundation
import VoiceChatKit

// Spec §2.1 — one session: one window, one MCP connection, one turn
// coordinator.

@MainActor
public final class Session {
    public let id: String
    public let firstTurnId = TurnSequence.first
    public let coordinator: TurnCoordinator
    public let model: ConversationModel
    public let windowController: ConversationWindowController
    private let speech = SpeechOutputController()
    private let listening = SpeechInputController()
    /// The current microphone lease, held only while this session is listening.
    private var micLease: MicrophoneLease?

    /// Notifies the peer that the session ended (`session.ended`).
    public var onEnded: (@Sendable (String, EndReason) -> Void)?
    public var onProgress: (@Sendable (String, TurnProgressParams.Phase) -> Void)?
    /// The window has actually closed — true disposal. Once this fires, the
    /// registry drops the session, so it can no longer be reopened from the
    /// menu bar.
    public var onDisposed: (@Sendable (String) -> Void)?

    /// The seat this window holds, when it is part of a debate.
    public let debateSeat: DebateSeat?

    public init(id: String, title: String?, hostName: String?, cwd: String? = nil,
                model modelName: String? = nil, debateSeat: DebateSeat? = nil) {
        self.id = id
        self.coordinator = TurnCoordinator()
        self.debateSeat = debateSeat
        // A debate seat never listens: its turns arrive as text from the other
        // seat, so opening with the mic live would take the microphone (and
        // raise a permission prompt) for a window that will never use it.
        self.model = ConversationModel(micEnabled: debateSeat == nil)
        self.model.hostName = hostName
        self.model.projectName = cwd.flatMap(Self.projectName(fromCwd:))
        self.model.workingDirectory = cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        self.model.currentModel = modelName
        let appName = "VoiceChat \(VoiceChatVersion.string)"
        // The host is shown in the header badge, so the title names only the
        // project, rather than repeating the host a few pixels away.
        let windowTitle = title ?? model.projectName.map { "\(appName) — \($0)" } ?? appName
        self.windowController = ConversationWindowController(
            model: model, title: windowTitle,
            autosaveName: debateSeat.map { "VoiceChatDebateSeat-\($0.key)" })

        wire()
        observeMute()
        observeTalkingHead()
        model.open()
    }

    /// The mute button lives in the shared window settings, so every session
    /// follows it — muting is about the machine's audio, not one conversation.
    private func observeMute() {
        withObservationTracking {
            _ = GlassSettings.shared.speechMuted
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMute() }
        }
        speech.isMuted = GlassSettings.shared.speechMuted
    }

    /// Like mute, the Talking Head toggle is shared by every window.
    private func observeTalkingHead() {
        withObservationTracking {
            _ = GlassSettings.shared.useTalkingHead
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTalkingHead() }
        }
        speech.useTalkingHead = GlassSettings.shared.useTalkingHead
    }

    /// The project a working directory names, or `nil` for the filesystem root.
    private static func projectName(fromCwd cwd: String) -> String? {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return (name.isEmpty || name == "/") ? nil : name
    }

    private func wire() {
        let coordinator = self.coordinator
        let id = self.id

        // R-UI-24 — VoiceOver and AVSpeechSynthesizer talking over each other is
        // unusable, so auto-play stays off while VoiceOver is running. The turn
        // then lands in Responding.Manual, ready for Play.
        model.speechAvailable = SpeechOutputController.isAvailable
            && !NSWorkspace.shared.isVoiceOverEnabled

        speech.onHighlight = { [weak self] range in self?.model.setHighlight(range) }
        speech.onFinished = { [weak self] in self?.model.speechFinished() }
        // A cancellation is always something the model already drove (Stop, Got
        // it!, or a fresh Play), so it must not re-enter the state machine.
        speech.onCancelled = { [weak self] in self?.model.setHighlight(nil) }

        model.onStartSpeech = { [weak self] attributed, selection in
            self?.speech.speak(attributed, selection: selection)
        }
        model.onStopSpeech = { [weak self] in self?.speech.stop() }

        // R-TTS-4 / R-TTS-9 — a single owner of the input device, driven only
        // by the state machine's recogniser effect.
        model.onRecognizer = { [weak self] action in
            guard let self else { return }
            switch action {
            case .stop:
                if let lease = self.micLease {
                    MicrophoneArbiter.shared.release(lease)
                    self.micLease = nil
                }
                Task { await self.listening.stop() }
            case .start:
                // R-STT-22 — taking the microphone stops whoever else had it,
                // and tells them so rather than leaving them silently deaf.
                self.micLease = MicrophoneArbiter.shared.acquire(id) { [weak self] in
                    guard let self else { return }
                    self.micLease = nil
                    self.model.setMicEnabled(false)
                    self.model.setMicStatus("Microphone taken by another conversation")
                }
                self.listening.contextualPhrases = self.model.vocabulary.load()
                Task { await self.listening.start() }
            case .unchanged:
                break
            }
        }

        listening.onVolatile = { [weak self] text in self?.model.setVolatile(text) }
        listening.onFinal = { [weak self] text in self?.model.handleFinalUtterance(text) }
        listening.onLevel = { [weak self] level in self?.model.setMicLevel(level) }
        listening.onStateChange = { [weak self] state in
            guard let self else { return }
            self.model.setMicStatus(Self.micStatus(for: state))
            self.model.setMicDenied(state == .microphoneDenied)
        }

        model.onVocabularyChanged = { [weak self] phrases in
            self?.listening.contextualPhrases = phrases
        }

        model.onTurnAdvanced = { [weak self] statement, _ in
            self?.onStatementCompleted?(statement)
        }

        model.onSubmitPrompt = { [weak self] text in
            guard let self else { return }
            let outgoing = self.debateSeat == nil
                ? text
                : DebateRoom.markModeratorEdits(sent: text, delivered: self.deliveredStatement)
            self.deliveredStatement = nil
            self.onPromptSent?()
            self.onProgress?(id, .idle)
            Task { await coordinator.markSubmitted() }
            Task { await coordinator.queuePrompt(outgoing) }
        }

        model.onEnd = { [weak self] reason in
            guard let self else { return }
            Task { await coordinator.end(reason) }
            self.onEnded?(id, reason)
            self.notifyDebateEnded()
            // The person ended it deliberately — close right away rather than
            // lingering on the banner.
            if reason == .userEnded {
                self.windowController.closeQuietly()
            } else {
                self.scheduleAutoClose()
            }
        }

        model.onRequestClose = { [weak self] in
            self?.windowController.closeQuietly()
        }

        windowController.onWindowClose = { [weak self] in
            guard let self else { return }
            guard self.model.canEnd else { return }
            self.model.endedByPeer(.windowClosed)
            Task { await coordinator.end(.windowClosed) }
            self.onEnded?(id, .windowClosed)
            self.notifyDebateEnded()
        }
        windowController.onWindowDidClose = { [weak self] in
            // A Talking Head window outliving its conversation cannot be
            // stopped from anywhere.
            self?.speech.stop()
            self?.onDisposed?(id)
        }
    }

    public func show() { windowController.present() }

    /// A debate seat is placed beside its opponent, and only the first seat
    /// takes focus — the second arriving must not snatch it away.
    public func show(seatIndex: Int, of seatCount: Int) {
        windowController.present(frame: DebateLayout.frame(seatIndex: seatIndex, seatCount: seatCount),
                                 activating: seatIndex == 0)
    }

    /// How this seat is spoken, so the two sides do not sound alike.
    public func applyDelivery(_ delivery: DebateVoices.Delivery) {
        speech.voiceIdentifier = delivery.voiceIdentifier
        speech.pitch = delivery.pitch
        speech.rate = delivery.rate
    }

    // MARK: Debate seat (R-DEB-1)

    public var onStatementCompleted: ((String) -> Void)?
    public var onPromptSent: (() -> Void)?
    public var onSessionEnded: (() -> Void)?
    /// Ending this session because the debate ended must not be reported back
    /// as a seat leaving, or the two seats would end each other in circles.
    private var isEndingForDebate = false
    /// The last statement put in this window's pane, so anything else that
    /// goes out is recognisably the moderator's.
    private var deliveredStatement: String?

    /// The host's MCP roots, reported after the session opened and whenever
    /// they change.
    public func setRoots(_ roots: [WorkspaceRoot]) { model.setRoots(roots) }

    /// The caller may identify itself differently on every `converse` call
    /// — refreshed once per turn, right before
    /// the daemon starts awaiting that turn.
    public func updateIdentity(model modelName: String?) {
        if let modelName { self.model.currentModel = modelName }
    }

    /// A response arrived from the peer (§5.2 row 6/7).
    public func present(response markdown: String) {
        model.present(response: markdown)
        onProgress?(id, model.machine.state.isResponding ? .speaking : .composing)
    }

    /// The peer ended the session: no confirmation, no callback outward.
    public func endFromPeer(_ reason: EndReason) {
        model.endedByPeer(reason)
        Task { [coordinator] in await coordinator.end(reason) }
        scheduleAutoClose()
        notifyDebateEnded()
    }

    private func notifyDebateEnded() {
        guard !isEndingForDebate else { return }
        isEndingForDebate = true
        onSessionEnded?()
    }

    /// R-STT-26 — a denial degrades speech and nothing else, so the wording
    /// says what still works.
    static func micStatus(for state: SpeechInputController.State) -> String {
        switch state {
        case .idle:              return ""
        case .preparing:         return "Preparing speech\u{2026}"
        case .listening:         return "Listening\u{2026}"
        case .microphoneDenied:  return "Microphone access denied \u{2014} you can still type"
        case .unavailable(let reason): return reason
        }
    }

    /// R-UI-20 — the closing banner lingers briefly, unless the history strip
    /// is open so a transcript can still be exported.
    private func scheduleAutoClose() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !self.model.historyExpanded else { return }
            self.windowController.closeQuietly()
        }
    }
}

// MARK: - A session as a debate seat

extension Session: DebateParticipant {
    public var seatKey: String { debateSeat?.key ?? id }

    /// The opponent's statement, put in this window's prompt pane. It is sent
    /// only when asked — normally the moderator presses Send.
    public func deliver(_ text: String, autoSend: Bool) {
        deliveredStatement = text
        model.submitPrompt(text, autoSend: autoSend)
    }

    public func setModeratorActions(skip: @escaping () -> Void, end: @escaping () -> Void,
                                    autoHandoff: @escaping (Bool) -> Void) {
        model.onDebateSkipTurn = skip
        model.onDebateEnd = end
        model.onDebateAutoHandoff = autoHandoff
    }

    public func showDebateStatus(_ badge: DebateBadge) {
        // The model is observed: assigning an equal badge would still
        // invalidate both windows' whole view bodies.
        guard model.debate != badge else { return }
        model.debate = badge
    }

    public func endDebate() {
        guard !isEndingForDebate else { return }
        // Set first, so `endFromPeer`'s own notification is the no-op that
        // stops the two seats ending each other in circles.
        isEndingForDebate = true
        endFromPeer(.userEnded)
        onEnded?(id, .userEnded)
    }
}
