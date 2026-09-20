import AppKit
import Testing
@testable import VoiceChatUI

// Mute silences the reading without stopping it. The important property is
// that toggling it never reaches the state machine: no finish, no cancel.

@MainActor
@Suite("Speech mute")
struct SpeechMuteTests {

    private func longReply() -> NSAttributedString {
        NSAttributedString(string: "This is the first sentence of a reply. Here is a second one. "
            + "A third sentence keeps it going. And a fourth so it cannot finish quickly.")
    }

    @Test("muted utterances are queued at zero volume, unmuted ones at the set volume")
    func effectiveVolume() {
        let speech = SpeechOutputController()
        speech.volume = 0.8
        #expect(speech.effectiveVolume == 0.8)
        speech.isMuted = true
        #expect(speech.effectiveVolume == 0)
        speech.isMuted = false
        #expect(speech.effectiveVolume == 0.8)
    }

    @Test("toggling mute while nothing is being read starts nothing")
    func idleToggleIsInert() async throws {
        let speech = SpeechOutputController()
        var finished = 0, cancelled = 0
        speech.onFinished = { finished += 1 }
        speech.onCancelled = { cancelled += 1 }

        speech.isMuted = true
        speech.isMuted = false

        try await Task.sleep(for: .milliseconds(200))
        #expect(!speech.isSpeaking)
        #expect(finished == 0)
        #expect(cancelled == 0)
    }

    @Test("muting and unmuting mid-reading keeps reading and never tells the state machine")
    func toggleMidReadingDoesNotEndIt() async throws {
        let speech = SpeechOutputController()
        var finished = 0, cancelled = 0
        speech.onFinished = { finished += 1 }
        speech.onCancelled = { cancelled += 1 }

        speech.speak(longReply())
        #expect(speech.isSpeaking)

        speech.isMuted = true
        #expect(speech.isSpeaking, "muting must not stop the reading")
        speech.isMuted = false
        #expect(speech.isSpeaking, "unmuting must not stop the reading")

        // Give the cancellations the re-issue causes time to arrive; they are
        // ours, not a Stop, so they must not surface as one.
        try await Task.sleep(for: .milliseconds(400))
        #expect(cancelled == 0)
        #expect(finished == 0, "the reading is nowhere near done")

        speech.stop()
    }
}
