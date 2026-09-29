import AppKit
import Foundation
import VoiceChatKit

/// Talking Head's two characters, as `th -v` names them.
public enum TalkingHeadVoice: String, CaseIterable, Sendable {
    case male, female

    var title: String { self == .male ? "Male (Daniel)" : "Female (Samantha)" }
    var symbol: String { self == .male ? "figure.stand" : "figure.stand.dress" }
    /// The other character — what the opposing debate seat is given.
    public var opposite: TalkingHeadVoice { self == .male ? .female : .male }
}

/// Reads a reply through Talking Head instead of the built-in synthesiser.
///
/// `R-TTS-19` — when Talking Head's menu bar app is running, the reply goes to
/// its speech spooler over the socket (`TalkingHeadSpooler`), whose events say
/// when the reading ends. Otherwise — no socket, or no reply within 300 ms —
/// it falls back to the `th` command: the text goes in on standard input, `th`
/// shows the animated face, speaks it, and exits. The reading is over when the
/// process is.
@MainActor
final class TalkingHeadSpeaker {

    /// Fires when the reading ends on its own (or could not start), so a turn
    /// is never stranded waiting on a reading that never ran. A reading
    /// stopped by someone else (Talking Head's own Stop) ends this way too.
    var onFinished: (() -> Void)?
    /// Fires when the reading ends because `stop()` ended it.
    var onCancelled: (() -> Void)?
    /// Talking Head refused or failed the reading (it still ends, as a finish).
    var onError: ((String) -> Void)?

    private let thURL: URL?
    private let socketPath: String

    // Touched only on the main actor, except from deinit, when nothing else
    // can reach this object any more.
    private nonisolated(unsafe) var process: Process?
    private var stopping = false
    private nonisolated(unsafe) var quitObserver: NSObjectProtocol?
    /// The spooler connection carrying the current reading.
    private nonisolated(unsafe) var spool: TalkingHeadSpoolerConnection?
    /// Waiting (up to 300 ms) to learn whether the spooler takes the reading.
    private var connecting = false
    /// Counts readings, so events from one that was stopped or replaced are
    /// ignored.
    private var reading = 0

    /// Talking Head's `th`, or nil when it is not installed. A GUI app does not
    /// inherit the shell's PATH, so the usual install locations are checked
    /// directly — and only a `th` that resolves into TalkingHead.app counts, so
    /// an unrelated program of the same name is never run.
    static let executableURL: URL? = {
        let candidates = [
            ("~/.local/bin/th" as NSString).expandingTildeInPath,
            "/usr/local/bin/th",
            "/opt/homebrew/bin/th",
            "/Applications/TalkingHead.app/Contents/MacOS/th",
        ]
        let files = FileManager.default
        for path in candidates where files.isExecutableFile(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if resolved.path.contains("/TalkingHead.app/") { return URL(fileURLWithPath: path) }
        }
        return nil
    }()

    static var isInstalled: Bool { executableURL != nil }

    var isRunning: Bool { connecting || spool != nil || (process?.isRunning ?? false) }
    /// Still waiting to learn whether the spooler takes the reading.
    var isConnecting: Bool { connecting }

    init(thURL: URL? = TalkingHeadSpeaker.executableURL,
         socketPath: String = TalkingHeadSpooler.socketPath) {
        self.thURL = thURL
        self.socketPath = socketPath
        // A child left speaking after VoiceChat quits would be an orphan
        // nobody can stop from here.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.process?.terminate()
                self?.spool?.close()
            }
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        process?.terminate()
        spool?.close()
    }

    func speak(_ text: String, voice: TalkingHeadVoice) {
        // A reading being replaced ends silently, as a replaced `th` always has.
        abandonSpooledReading()
        stop()
        stopping = false

        reading += 1
        let id = reading
        connecting = true
        let path = socketPath
        let request = TalkingHeadSpoolerRequest.speak(text, voice: voice.rawValue)
        // Connecting and waiting for the first reply happen off the main actor.
        Task.detached { [weak self] in
            let connection = TalkingHeadSpoolerConnection.open(at: path)
            let first = connection.flatMap { $0.send(request) ? $0.nextEvent(timeout: TalkingHeadSpooler.replyTimeout) : nil }
            await self?.spoolerAnswered(connection, first: first, reading: id, text: text, voice: voice)
        }
    }

    // MARK: Through the spooler

    private func spoolerAnswered(_ connection: TalkingHeadSpoolerConnection?, first: TalkingHeadSpoolerEvent?,
                                 reading id: Int, text: String, voice: TalkingHeadVoice) {
        guard id == reading, connecting else {
            // Stopped or replaced while connecting: closing takes the speech back.
            connection?.close()
            return
        }
        connecting = false
        guard let connection, let first else {
            // No Talking Head listening, or one that didn't answer in time.
            connection?.close()
            runTH(text, voice: voice)
            return
        }
        spool = connection
        handle(first, reading: id)
        guard spool != nil else { return }
        Task.detached { [weak self] in
            while let event = connection.nextEvent() {
                await self?.handle(event, reading: id)
                if event.isFinal { return }
            }
            // The connection ended without a result: Talking Head quit.
            await self?.spoolEnded(reading: id)
        }
    }

    private func handle(_ event: TalkingHeadSpoolerEvent, reading id: Int) {
        guard id == reading, spool != nil else { return }
        switch event.kind {
        case .finished, .stopped:
            // A `stopped` here was not asked for by VoiceChat (its own Stop
            // closes the connection first): Talking Head's Stop, or an agent's.
            // The reading is over, as a finish, so the turn moves on as usual.
            endSpooledReading()
        case .error:
            onError?(event.message ?? "Talking Head couldn't read the reply.")
            endSpooledReading()
        case .queued, .started, .presence, nil:
            break
        }
    }

    private func spoolEnded(reading id: Int) {
        guard id == reading, spool != nil else { return }
        endSpooledReading()
    }

    private func endSpooledReading() {
        spool?.close()
        spool = nil
        onFinished?()
    }

    /// Ends a spooled reading (or the wait for one) without a word to anyone.
    private func abandonSpooledReading() {
        guard connecting || spool != nil else { return }
        reading += 1
        connecting = false
        spool?.close()
        spool = nil
    }

    // MARK: Through `th`

    private func runTH(_ text: String, voice: TalkingHeadVoice) {
        guard let url = thURL else {
            finishSoon()
            return
        }

        let process = Process()
        process.executableURL = url
        // Like the conversation window, the face must not hide behind other
        // apps' windows while it is the thing being listened to.
        process.arguments = ["--always-on-top", "-v", voice.rawValue]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.processEnded(ended) }
        }

        do {
            try process.run()
        } catch {
            NSLog("VoiceChat: could not launch Talking Head: \(error)")
            finishSoon()
            return
        }
        self.process = process

        // `th` reads standard input to the end before speaking, so the write
        // end must be closed. Writing off the main actor keeps a long reply
        // from blocking the UI on a full pipe buffer.
        let data = Data(text.utf8)
        let handle = input.fileHandleForWriting
        Task.detached {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    func stop() {
        if connecting || spool != nil {
            // Closing the connection takes the speech back from the spooler.
            abandonSpooledReading()
            Task { @MainActor [weak self] in self?.onCancelled?() }
            return
        }
        guard let process, process.isRunning else { return }
        stopping = true
        process.terminate()
    }

    private func processEnded(_ ended: Process) {
        // A stale exit from a process a newer `speak` already replaced.
        guard ended === process else { return }
        process = nil
        if stopping {
            stopping = false
            onCancelled?()
        } else {
            onFinished?()
        }
    }

    /// Deferred a tick so the state machine is not re-entered mid-transition.
    private func finishSoon() {
        Task { @MainActor [weak self] in self?.onFinished?() }
    }
}
