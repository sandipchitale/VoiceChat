import AVFoundation
import AppKit
import Foundation

// Spec §9 — local speech synthesis.

@MainActor
public final class SpeechOutputController: NSObject {

    private let synthesizer = AVSpeechSynthesizer()
    private var segments: [SpeechSegment] = []
    private var utteranceSegment: [ObjectIdentifier: Int] = [:]
    private var lastEnqueued = -1
    private var stopping = false

    /// Highlight the sentence being spoken (R-UI-8); nil clears it.
    public var onHighlight: ((NSRange?) -> Void)?
    /// Fires on natural completion *and* on cancellation, because §5.2 rows 8
    /// and 11 both hang off "the synthesiser stopped".
    public var onFinished: (() -> Void)?
    public var onCancelled: (() -> Void)?

    public var options = SpeechBuildOptions()
    public var voiceIdentifier: String?
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var pitch: Float = 1.0
    public var volume: Float = 1.0

    /// Mute silences the audio but leaves the reading running — the highlight,
    /// the timing and the auto-advance are all unchanged, so muting can never
    /// strand or skip a turn. An utterance's volume is fixed the moment it is
    /// queued, so changing this mid-reading re-issues the queue from the
    /// sentence being read: that sentence starts over, silently or audibly.
    public var isMuted = false {
        didSet {
            guard isMuted != oldValue else { return }
            // Talking Head cannot be silenced mid-reading, and muting means
            // silence, so it is ended — as a finish, so the turn moves on.
            if isMuted, talkingHead.isRunning {
                talkingHeadMuted = true
                talkingHead.stop()
                return
            }
            reissueQueue()
        }
    }

    /// Read replies through Talking Head's `th` instead of the synthesiser,
    /// when it is installed. Takes effect from the next reading.
    public var useTalkingHead = false

    private lazy var talkingHead: TalkingHeadSpeaker = {
        let speaker = TalkingHeadSpeaker()
        speaker.onFinished = { [weak self] in self?.talkingHeadEnded(cancelled: false) }
        speaker.onCancelled = { [weak self] in
            guard let self else { return }
            // Ended by mute: a finish. Ended by stop(): a cancellation.
            let muted = self.talkingHeadMuted
            self.talkingHeadMuted = false
            self.talkingHeadEnded(cancelled: !muted)
        }
        return speaker
    }()
    private var talkingHeadMuted = false

    /// The volume utterances are queued with.
    public var effectiveVolume: Float { isMuted ? 0 : volume }

    public private(set) var isSpeaking = false
    private var currentSegment: Int?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// R-TTS-3 — a locally installed voice, never a network one.
    public static var isAvailable: Bool {
        !AVSpeechSynthesisVoice.speechVoices().isEmpty
    }

    // MARK: Speaking

    /// R-TTS-15 — Play reads the selection if there is one, otherwise the whole
    /// response from the top. Resuming mid-response is not offered: after an
    /// edit it is ambiguous, and restarting is cheap.
    public func speak(_ attributed: NSAttributedString, selection: NSRange? = nil) {
        stop()
        stopping = false

        let source: NSAttributedString
        let offset: Int
        if let selection, selection.length > 0, NSMaxRange(selection) <= attributed.length {
            source = attributed.attributedSubstring(from: selection)
            offset = selection.location
        } else {
            source = attributed
            offset = 0
        }

        let built = SpeechTextBuilder.segments(from: source, options: options)
        segments = offset == 0 ? built : built.map {
            SpeechSegment(text: $0.text,
                          range: NSRange(location: $0.range.location + offset, length: $0.range.length),
                          postDelay: $0.postDelay)
        }

        let speakable = segments.enumerated().filter { $0.element.isSpoken }
        guard !speakable.isEmpty else {
            // Nothing to say — treated as finishing immediately, so a response
            // with no readable content cannot strand the turn (§5.4). Deferred
            // a tick so the state machine is not re-entered mid-transition.
            Task { @MainActor [weak self] in self?.onFinished?() }
            return
        }

        if useTalkingHead, !isMuted, TalkingHeadSpeaker.isInstalled {
            // `th` reports no progress, so there is no sentence highlight.
            isSpeaking = true
            onHighlight?(nil)
            talkingHead.speak(speakable.map(\.element.text).joined(separator: "\n"))
            return
        }

        enqueue(speakable)
    }

    private func talkingHeadEnded(cancelled: Bool) {
        // A late exit from a `th` that a fresh Play replaced with the
        // synthesiser must not touch that reading.
        guard !synthesizer.isSpeaking else {
            if cancelled { onCancelled?() }
            return
        }
        isSpeaking = false
        onHighlight?(nil)
        if cancelled { onCancelled?() } else { onFinished?() }
    }

    private func enqueue(_ speakable: [(offset: Int, element: SpeechSegment)]) {
        isSpeaking = true
        lastEnqueued = speakable.last!.offset
        for (index, segment) in speakable {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.rate = rate
            utterance.pitchMultiplier = pitch
            utterance.volume = effectiveVolume
            utterance.postUtteranceDelay = segment.postDelay
            if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }
            utteranceSegment[ObjectIdentifier(utterance)] = index
            synthesizer.speak(utterance)
        }
    }

    /// Not a stop: `stopping` stays false, so the cancellations this causes are
    /// ignored and nothing reaches the state machine.
    private func reissueQueue() {
        guard isSpeaking else { return }
        let resume = currentSegment ?? 0
        synthesizer.stopSpeaking(at: .immediate)
        utteranceSegment.removeAll()
        let remaining = segments.enumerated().filter { $0.element.isSpoken && $0.offset >= resume }
        guard !remaining.isEmpty else { return }
        enqueue(remaining)
    }

    public func stop() {
        if talkingHead.isRunning {
            talkingHeadMuted = false
            talkingHead.stop()
            isSpeaking = false
            currentSegment = nil
            onHighlight?(nil)
            return
        }
        guard isSpeaking || synthesizer.isSpeaking else {
            onHighlight?(nil)
            return
        }
        stopping = true
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentSegment = nil
        onHighlight?(nil)
        utteranceSegment.removeAll()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechOutputController: AVSpeechSynthesizerDelegate {

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              willSpeakRangeOfSpeechString characterRange: NSRange,
                                              utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let index = self.utteranceSegment[key], index < self.segments.count else { return }
            self.currentSegment = index
            let segment = self.segments[index]
            // The utterance string can carry a prefix ("Quote: "), so clamp
            // rather than trusting the offset to land inside the document.
            let location = segment.range.location + min(characterRange.location, segment.range.length)
            let length = min(characterRange.length, max(0, NSMaxRange(segment.range) - location))
            self.onHighlight?(NSRange(location: location, length: length))
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let index = self.utteranceSegment[key] else { return }
            guard index == self.lastEnqueued, !self.stopping else { return }
            self.isSpeaking = false
            self.currentSegment = nil
            self.onHighlight?(nil)
            self.utteranceSegment.removeAll()
            self.onFinished?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.stopping else { return }
            self.stopping = false
            self.isSpeaking = false
            self.onHighlight?(nil)
            self.onCancelled?()
        }
    }
}
