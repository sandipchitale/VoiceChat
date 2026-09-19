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

    public private(set) var isSpeaking = false

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

        isSpeaking = true
        lastEnqueued = speakable.last!.offset
        for (index, segment) in speakable {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.rate = rate
            utterance.pitchMultiplier = pitch
            utterance.volume = volume
            utterance.postUtteranceDelay = segment.postDelay
            if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }
            utteranceSegment[ObjectIdentifier(utterance)] = index
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        guard isSpeaking || synthesizer.isSpeaking else {
            onHighlight?(nil)
            return
        }
        stopping = true
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
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
