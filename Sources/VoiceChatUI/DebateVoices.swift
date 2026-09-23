import AVFoundation
import Foundation
import VoiceChatKit

// Two debaters, two voices. A debate whose sides sound alike is hard to follow,
// especially for someone watching with the sound off and reading the
// highlight, so the seats are always made to differ — by voice where the Mac
// has two installed, and by pitch and rate where it does not.
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

    /// The installed voices for the interface language, newest style first.
    public static func installed() -> [(name: String, identifier: String)] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .map { (name: $0.name, identifier: $0.identifier) }
            .sorted { $0.name < $1.name }
    }

    /// A delivery per seat, in seat order, guaranteed to differ from each other.
    /// `available` is injectable so the rule can be tested without the Mac's
    /// own voice list.
    public static func deliveries(for seats: [DebateSeat],
                                  available: [(name: String, identifier: String)]) -> [Delivery] {
        var used: Set<String> = []
        var deliveries: [Delivery] = []

        for seat in seats {
            let chosen = resolve(seat.voice, in: available)
            // A voice already spoken for is no use: take the next free one.
            let identifier = (chosen.map { used.contains($0) ? nil : $0 } ?? nil)
                ?? available.map(\.identifier).first { !used.contains($0) }
            if let identifier { used.insert(identifier) }
            deliveries.append(Delivery(voiceIdentifier: identifier))
        }

        // Not enough distinct voices on this Mac: separate the seats by pitch
        // and rate instead, so they are still told apart by ear.
        let distinct = Set(deliveries.compactMap(\.voiceIdentifier))
        if distinct.count < seats.count {
            for index in deliveries.indices {
                let step = Float(index) - Float(deliveries.count - 1) / 2
                deliveries[index].pitch = 1.0 + 0.15 * step
                deliveries[index].rate = AVSpeechUtteranceDefaultSpeechRate * (1.0 + 0.08 * step)
            }
        }
        return deliveries
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
