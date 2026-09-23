import AVFoundation
import Foundation
import VoiceChatKit

// How a debate's seats are spoken.
//
// Both seats use the Mac's standard voice unless the person picks otherwise:
// choosing for them lands on whatever sorts first, which on macOS means the
// novelty voices (Albert, Bad News, Bubbles…) and makes a debate ridiculous.
// The sides are instead separated by a small pitch and rate difference, which
// is enough to tell them apart while both still sound normal.
//
// A missing or misspelled voice never fails a debate; it falls back.

public enum DebateVoices {

    /// How a seat should be spoken.
    public struct Delivery: Sendable, Equatable {
        public var voiceIdentifier: String?
        public var pitch: Float
        public var rate: Float

        public init(voiceIdentifier: String? = nil,
                    pitch: Float = 1.0,
                    rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
            self.voiceIdentifier = voiceIdentifier
            self.pitch = pitch
            self.rate = rate
        }
    }

    /// Legacy novelty voices — "Bad News", "Boing", "Bubbles" — all share this
    /// prefix. Nobody wants a debate argued by them, so they are kept out of
    /// the picker.
    private static let noveltyPrefix = "com.apple.speech.synthesis.voice."

    /// The speaking voices installed for the interface language.
    public static func installed() -> [(name: String, identifier: String)] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.identifier.hasPrefix(noveltyPrefix) }
            .map { (name: $0.name, identifier: $0.identifier) }
            .sorted { $0.name < $1.name }
    }

    /// A delivery per seat, in seat order. A seat speaks in the voice the
    /// person chose for it, or in the Mac's standard voice; either way the
    /// seats are given slightly different pitch and rate so they are still
    /// told apart by ear. `available` is injectable so the rule can be tested
    /// without the Mac's own voice list.
    public static func deliveries(for seats: [DebateSeat],
                                  available: [(name: String, identifier: String)]) -> [Delivery] {
        seats.enumerated().map { index, seat in
            // Nil means the system voice — never a voice picked on the
            // person's behalf.
            var delivery = Delivery(voiceIdentifier: resolve(seat.voice, in: available))
            let step = Float(index) - Float(seats.count - 1) / 2
            delivery.pitch = 1.0 + 0.12 * step
            delivery.rate = AVSpeechUtteranceDefaultSpeechRate * (1.0 + 0.06 * step)
            return delivery
        }
    }

    /// A seat's requested voice: an identifier, or a name like "Samantha".
    static func resolve(_ requested: String?,
                        in available: [(name: String, identifier: String)]) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        if let exact = available.first(where: { $0.identifier == requested }) {
            return exact.identifier
        }
        return available.first { $0.name.caseInsensitiveCompare(requested) == .orderedSame }?
            .identifier
    }
}
