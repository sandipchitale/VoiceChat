import Foundation
import Testing
@testable import VoiceChatKit

@Suite("Talking Head presence mapping (R-TTS-17)")
struct TalkingHeadPresenceMappingTests {

    @Test("every state maps as the table says",
          arguments: [
              (SessionState.idle, false, TalkingHeadPresence.none),
              (.composing, false, .listening),
              (.submitted, false, .thinking),
              (.respondingAuto, true, .none),
              (.respondingAuto, false, .none),
              (.respondingManual, true, .none),
              (.respondingManual, false, .listening),
              (.ended(.userEnded), false, .none),
              (.ended(.windowClosed), false, .none),
          ])
    func table(state: SessionState, speaking: Bool, expected: TalkingHeadPresence) {
        #expect(TalkingHeadPresence.for(state: state, isSpeaking: speaking, talkingHeadOn: true, muted: false) == expected)
    }

    @Test("Talking Head off or muted shows nothing, in every state")
    func offOrMuted() {
        let states: [SessionState] = [.idle, .composing, .submitted, .respondingAuto, .respondingManual, .ended(.userEnded)]
        for state in states {
            for speaking in [false, true] {
                #expect(TalkingHeadPresence.for(state: state, isSpeaking: speaking, talkingHeadOn: false, muted: false) == .none)
                #expect(TalkingHeadPresence.for(state: state, isSpeaking: speaking, talkingHeadOn: true, muted: true) == .none)
            }
        }
    }
}

@Suite("Talking Head presence sequencing")
struct TalkingHeadPresenceSequenceTests {

    /// Drives the machine through `events`, collecting what would be sent.
    private func sent(_ events: [SessionEvent], autoPlay: Bool = true) -> [TalkingHeadPresence] {
        var machine = SessionMachine()
        machine.autoPlayEnabled = autoPlay
        var sequencer = PresenceSequencer()
        var out: [TalkingHeadPresence] = []
        for event in events {
            machine.handle(event)
            let presence = TalkingHeadPresence.for(state: machine.state, isSpeaking: machine.isSpeaking,
                                                   talkingHeadOn: true, muted: false)
            if let change = sequencer.next(presence) { out.append(change) }
        }
        return out
    }

    @Test("a full turn: listening → thinking → none → listening, no duplicates")
    func fullTurn() {
        let out = sent([.sessionOpened, .setMicEnabled(false), .setMicEnabled(true), .send(isEmpty: true),
                        .send(isEmpty: false), .responseReceived(isEmpty: false), .speechFinished,
                        .send(isEmpty: false)])
        #expect(out == [.listening, .thinking, .none, .listening, .thinking])
    }

    @Test("Stop → Play → Got it: listening while paused, none while read, listening next turn")
    func stopPlayGotIt() {
        let out = sent([.sessionOpened, .send(isEmpty: false), .responseReceived(isEmpty: false),
                        .stop, .play, .speechFinished, .gotIt])
        // respondingAuto (none) → Stop: manual, paused (listening) → Play (none) → finished in manual
        // (listening) → Got it: composing (listening, unchanged).
        #expect(out == [.listening, .thinking, .none, .listening, .none, .listening])
    }

    @Test("an empty response goes straight back to listening")
    func emptyResponse() {
        #expect(sent([.sessionOpened, .send(isEmpty: false), .responseReceived(isEmpty: true)])
                == [.listening, .thinking, .listening])
    }

    @Test("ending clears the face")
    func ending() {
        #expect(sent([.sessionOpened, .send(isEmpty: false), .end(.userEnded)]) == [.listening, .thinking, .none])
    }

    @Test("reset: after the face was let go, the same presence is sent again")
    func reset() {
        var sequencer = PresenceSequencer()
        var sent: [TalkingHeadPresence?] = []
        sent.append(sequencer.next(.none))
        sent.append(sequencer.next(.listening))
        sent.append(sequencer.next(.listening))
        sequencer.reset()
        sent.append(sequencer.next(.listening))
        #expect(sent == [nil, .listening, nil, .listening])
    }
}

@Suite("Nod throttle (R-TTS-18)")
struct NodThrottleTests {
    @Test("at most one nod per 600 ms")
    func throttle() {
        var throttle = NodThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let nods = [0, 0.2, 0.59, 0.6, 1.0, 1.3].map { throttle.shouldNod(at: start.addingTimeInterval($0)) }
        #expect(nods == [true, false, false, true, false, true])
    }
}

@Suite("Talking Head spooler codec")
struct TalkingHeadSpoolerCodecTests {
    @Test("requests match Talking Head's protocol")
    func requests() {
        #expect(String(decoding: TalkingHeadSpoolerRequest.speak("Hi", voice: "female").line, as: UTF8.self)
                == #"{"alwaysOnTop":true,"text":"Hi","type":"speak","voice":"female"}"# + "\n")
        #expect(String(decoding: TalkingHeadSpoolerRequest.presence(.thinking, voice: "male").line, as: UTF8.self)
                == #"{"state":"thinking","type":"presence","voice":"male"}"# + "\n")
        #expect(String(decoding: TalkingHeadSpoolerRequest.presence(.listening, nod: true).line, as: UTF8.self)
                == #"{"pulse":"nod","state":"listening","type":"presence"}"# + "\n")
    }

    @Test("events decode; unknown types and fields don't break decoding")
    func events() throws {
        let decode = { (json: String) in try JSONDecoder().decode(TalkingHeadSpoolerEvent.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"type":"finished"}"#).isFinal)
        let error = try decode(#"{"type":"error","message":"Nope."}"#)
        #expect(error.kind == .error && error.message == "Nope." && error.isFinal)
        #expect(try decode(#"{"type":"presence"}"#).kind == .presence)
        let future = try decode(#"{"type":"wink","extra":1}"#)
        #expect(future.kind == nil && !future.isFinal)
    }

    @Test("no socket: no connection")
    func noSocket() {
        #expect(TalkingHeadSpoolerConnection.open(at: NSTemporaryDirectory() + "no-such-\(UUID().uuidString.prefix(6)).sock") == nil)
    }
}
