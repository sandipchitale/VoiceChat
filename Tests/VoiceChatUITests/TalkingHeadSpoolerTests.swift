import Foundation
import Testing
import VoiceChatKit
@testable import VoiceChatUI

/// A stand-in for Talking Head's spooler: a Unix socket in the temporary
/// folder that records what each connection sends and answers as told.
final class FakeSpooler: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var _received: [String] = []
    private var _closed = 0
    /// Lines to answer a request with (by its "type"); none means silence, and
    /// `FakeSpooler.hangUp` ends the connection (as when Talking Head quits).
    private let answer: @Sendable (_ type: String) -> [String]

    static let hangUp = "HANGUP"

    var received: [String] { lock.withLock { _received } }
    /// How many connections have ended.
    var closed: Int { lock.withLock { _closed } }

    init(answer: @escaping @Sendable (_ type: String) -> [String]) throws {
        path = NSTemporaryDirectory() + "vc-th-\(UUID().uuidString.prefix(8)).sock"
        self.answer = answer
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit {
        Darwin.close(listener)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 4096)
        reading: while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0, let lines = try? framer.append(Data(buffer[0..<count])) else { break }
            for line in lines {
                let text = String(decoding: line, as: UTF8.self)
                lock.withLock { _received.append(text) }
                let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                for reply in answer(object?["type"] as? String ?? "") {
                    if reply == Self.hangUp { break reading }
                    _ = (reply + "\n").withCString { write(client, $0, strlen($0)) }
                }
            }
        }
        Darwin.close(client)
        lock.withLock { _closed += 1 }
    }
}

/// Waits (briefly) until `condition` holds.
@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A fake `th`: reads standard input, then exits 0 (after `delay` seconds).
func fakeTH(delay: Double = 0) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "fake-th-\(UUID().uuidString.prefix(8))")
    try "#!/bin/sh\ncat > /dev/null\nsleep \(delay)\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@MainActor
@Suite("Talking Head speaker over the spooler (R-TTS-19, R-TTS-20)")
struct TalkingHeadSpeakerSpoolerTests {

    /// What the speaker reported, in order.
    private final class Outcome {
        var events: [String] = []
    }

    private func speaker(_ spooler: FakeSpooler?, th: URL? = nil) -> (TalkingHeadSpeaker, Outcome) {
        let outcome = Outcome()
        let path = spooler?.path ?? NSTemporaryDirectory() + "absent-\(UUID().uuidString.prefix(6)).sock"
        let speaker = TalkingHeadSpeaker(thURL: th, socketPath: path)
        speaker.onFinished = { outcome.events.append("finished") }
        speaker.onCancelled = { outcome.events.append("cancelled") }
        speaker.onError = { outcome.events.append("error: \($0)") }
        return (speaker, outcome)
    }

    @Test("finished → onFinished")
    func finished() async throws {
        let spooler = try FakeSpooler { _ in [#"{"type":"queued"}"#, #"{"type":"started"}"#, #"{"type":"finished"}"#] }
        let (speaker, outcome) = speaker(spooler)
        speaker.speak("Hello there.", voice: .female)
        #expect(speaker.isRunning)
        await eventually { !outcome.events.isEmpty }
        #expect(outcome.events == ["finished"])
        #expect(!speaker.isRunning)
        #expect(spooler.received == [#"{"alwaysOnTop":true,"text":"Hello there.","type":"speak","voice":"female"}"#])
    }

    @Test("a stop VoiceChat didn't ask for (Talking Head's own Stop) → onFinished")
    func stoppedElsewhere() async throws {
        let spooler = try FakeSpooler { _ in [#"{"type":"queued"}"#, #"{"type":"stopped"}"#] }
        let (speaker, outcome) = speaker(spooler)
        speaker.speak("Hello.", voice: .male)
        await eventually { !outcome.events.isEmpty }
        #expect(outcome.events == ["finished"])
    }

    @Test("error → onFinished, with the warning")
    func error() async throws {
        let spooler = try FakeSpooler { _ in [#"{"type":"queued"}"#, #"{"type":"error","message":"Can't speak that."}"#] }
        let (speaker, outcome) = speaker(spooler)
        speaker.speak("Hello.", voice: .male)
        await eventually { outcome.events.count == 2 }
        #expect(outcome.events == ["error: Can't speak that.", "finished"])
    }

    @Test("Stop closes the speech's connection → onCancelled")
    func stop() async throws {
        let spooler = try FakeSpooler { _ in [#"{"type":"queued"}"#, #"{"type":"started"}"#] }  // speaks for ever
        let (speaker, outcome) = speaker(spooler)
        speaker.speak("A long reply.", voice: .male)
        await eventually { spooler.received.count == 1 && !speaker.isConnecting }
        speaker.stop()
        #expect(!speaker.isRunning)
        await eventually { !outcome.events.isEmpty && spooler.closed == 1 }
        #expect(outcome.events == ["cancelled"])
        #expect(spooler.closed == 1)
    }

    @Test("Talking Head quitting mid-reading doesn't strand the turn")
    func talkingHeadQuits() async throws {
        // Takes the speech, starts it, then hangs up (as when the app quits).
        let spooler = try FakeSpooler { _ in [#"{"type":"queued"}"#, #"{"type":"started"}"#, FakeSpooler.hangUp] }
        let (speaker, outcome) = speaker(spooler)
        speaker.speak("Hello.", voice: .male)
        await eventually { !outcome.events.isEmpty }
        #expect(outcome.events == ["finished"])
    }

    @Test("no socket: falls back to th")
    func noSocketFallsBack() async throws {
        let (speaker, outcome) = speaker(nil, th: try fakeTH())
        speaker.speak("Hello.", voice: .male)
        await eventually { !outcome.events.isEmpty }
        #expect(outcome.events == ["finished"])
    }

    @Test("no reply within 300 ms: falls back to th, and the spooler's copy is taken back")
    func silentSpoolerFallsBack() async throws {
        let spooler = try FakeSpooler { _ in [] }
        let (speaker, outcome) = speaker(spooler, th: try fakeTH(delay: 0.2))
        let start = Date()
        speaker.speak("Hello.", voice: .male)
        await eventually { spooler.closed == 1 }
        #expect(spooler.closed == 1)
        #expect(speaker.isRunning)  // now `th`
        await eventually { !outcome.events.isEmpty }
        #expect(outcome.events == ["finished"])
        #expect(Date().timeIntervalSince(start) >= 0.3)
    }

    @Test("no socket and no th: finishes at once rather than stranding the turn")
    func nothingInstalled() async {
        let (speaker, outcome) = speaker(nil, th: nil)
        speaker.speak("Hello.", voice: .male)
        await eventually { !outcome.events.isEmpty }
        #expect(outcome.events == ["finished"])
    }
}

@MainActor
@Suite("Talking Head presence link (R-TTS-17, R-TTS-18, R-TTS-21)")
struct TalkingHeadPresenceLinkTests {

    private func machine(_ events: SessionEvent...) -> SessionMachine {
        var machine = SessionMachine()
        for event in events { machine.handle(event) }
        return machine
    }

    @Test("sends only changes over one connection, kept through responding, closed at the end")
    func turn() async throws {
        let spooler = try FakeSpooler { type in type == "presence" ? [#"{"type":"presence"}"#] : [] }
        let link = TalkingHeadPresenceLink(socketPath: spooler.path)
        func update(_ m: SessionMachine) { link.update(machine: m, talkingHeadOn: true, muted: false, voice: .female) }

        update(machine())                                                  // idle: nothing
        update(machine(.sessionOpened))                                    // listening
        update(machine(.sessionOpened))                                    // unchanged
        update(machine(.sessionOpened, .send(isEmpty: false)))             // thinking
        let responding = machine(.sessionOpened, .send(isEmpty: false), .responseReceived(isEmpty: false))
        update(responding)                                                 // none, connection kept
        update(machine(.sessionOpened, .send(isEmpty: false), .responseReceived(isEmpty: false), .speechFinished))
        await eventually { spooler.received.count == 4 }
        #expect(spooler.received == [
            #"{"state":"listening","type":"presence","voice":"female"}"#,
            #"{"state":"thinking","type":"presence","voice":"female"}"#,
            #"{"state":"none","type":"presence","voice":"female"}"#,
            #"{"state":"listening","type":"presence","voice":"female"}"#,
        ])
        #expect(spooler.closed == 0)

        update(machine(.sessionOpened, .end(.userEnded)))
        await eventually { spooler.closed == 1 }
        #expect(spooler.closed == 1)
        #expect(link.log.last == "close")
        #expect(!link.isUnsupported)
    }

    @Test("mute and Talking Head off let the face go; unmuting brings it back")
    func muteAndOff() async throws {
        let spooler = try FakeSpooler { type in type == "presence" ? [#"{"type":"presence"}"#] : [] }
        let link = TalkingHeadPresenceLink(socketPath: spooler.path)
        let composing = machine(.sessionOpened)
        link.update(machine: composing, talkingHeadOn: true, muted: false, voice: .male)
        link.update(machine: composing, talkingHeadOn: true, muted: true, voice: .male)
        await eventually { spooler.closed == 1 }
        link.update(machine: composing, talkingHeadOn: true, muted: false, voice: .male)
        link.update(machine: composing, talkingHeadOn: false, muted: false, voice: .male)
        await eventually { spooler.closed == 2 }
        #expect(link.log == ["listening male", "close", "listening male", "close"])
    }

    @Test("a changed seat voice is sent even when the presence isn't")
    func voiceChange() async throws {
        let spooler = try FakeSpooler { type in type == "presence" ? [#"{"type":"presence"}"#] : [] }
        let link = TalkingHeadPresenceLink(socketPath: spooler.path)
        let composing = machine(.sessionOpened)
        link.update(machine: composing, talkingHeadOn: true, muted: false, voice: .male)
        link.update(machine: composing, talkingHeadOn: true, muted: false, voice: .female)
        #expect(link.log == ["listening male", "listening female"])
    }

    @Test("nods are throttled, and only while listening and acknowledged")
    func nods() async throws {
        let spooler = try FakeSpooler { type in type == "presence" ? [#"{"type":"presence"}"#] : [] }
        let link = TalkingHeadPresenceLink(socketPath: spooler.path)
        link.nod(voice: .male)                                             // no connection yet
        link.update(machine: machine(.sessionOpened), talkingHeadOn: true, muted: false, voice: .male)
        await eventually { spooler.received.count == 1 }
        try await Task.sleep(for: .milliseconds(30))                       // the acknowledgement lands
        link.nod(voice: .male)
        link.nod(voice: .male)                                             // within 600 ms: dropped
        link.update(machine: machine(.sessionOpened, .send(isEmpty: false)), talkingHeadOn: true, muted: false, voice: .male)
        try await Task.sleep(for: .milliseconds(650))
        link.nod(voice: .male)                                             // thinking: no nod
        #expect(link.log == ["listening male", "nod", "thinking male"])
        await eventually { spooler.received.count == 3 }
        #expect(spooler.received[1] == #"{"pulse":"nod","state":"listening","type":"presence","voice":"male"}"#)
    }

    @Test("an older Talking Head (presence answered with an error): no presence, and nothing more")
    func unsupported() async throws {
        let spooler = try FakeSpooler { _ in [#"{"type":"error","message":"Talking Head couldn't understand the request."}"#] }
        let link = TalkingHeadPresenceLink(socketPath: spooler.path)
        link.update(machine: machine(.sessionOpened), talkingHeadOn: true, muted: false, voice: .male)
        await eventually { link.isUnsupported }
        #expect(link.isUnsupported)
        await eventually { spooler.closed == 1 }
        link.update(machine: machine(.sessionOpened, .send(isEmpty: false)), talkingHeadOn: true, muted: false, voice: .male)
        #expect(spooler.received.count == 1)
    }

    @Test("a Talking Head that doesn't answer within 300 ms is treated as unsupported")
    func silent() async throws {
        let spooler = try FakeSpooler { _ in [] }
        let link = TalkingHeadPresenceLink(socketPath: spooler.path)
        link.update(machine: machine(.sessionOpened), talkingHeadOn: true, muted: false, voice: .male)
        await eventually { link.isUnsupported }
        #expect(link.isUnsupported)
        await eventually { spooler.closed == 1 }
        #expect(spooler.closed == 1)
    }

    @Test("no Talking Head running: nothing is sent, and nothing breaks")
    func absent() {
        let link = TalkingHeadPresenceLink(socketPath: NSTemporaryDirectory() + "absent-\(UUID().uuidString.prefix(6)).sock")
        link.update(machine: machine(.sessionOpened), talkingHeadOn: true, muted: false, voice: .male)
        #expect(link.log.isEmpty)
        #expect(!link.isUnsupported)
    }
}
