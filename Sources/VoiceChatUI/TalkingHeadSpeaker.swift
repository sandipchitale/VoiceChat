import AppKit
import Foundation

/// Reads a reply through Talking Head's `th` command instead of the built-in
/// synthesiser: the text goes in on standard input, `th` shows the animated
/// face, speaks it, and exits. The reading is over when the process is.
/// Talking Head's two characters, as `th -v` names them.
public enum TalkingHeadVoice: String, CaseIterable, Sendable {
    case male, female

    var title: String { self == .male ? "Male (Daniel)" : "Female (Samantha)" }
    var symbol: String { self == .male ? "figure.stand" : "figure.stand.dress" }
    /// The other character — what the opposing debate seat is given.
    public var opposite: TalkingHeadVoice { self == .male ? .female : .male }
}

@MainActor
final class TalkingHeadSpeaker {

    /// Fires when `th` exits on its own (or could not be launched), so a turn
    /// is never stranded waiting on a process that never ran.
    var onFinished: (() -> Void)?
    /// Fires when `th` exits because `stop()` ended it.
    var onCancelled: (() -> Void)?

    // Touched only on the main actor, except from deinit, when nothing else
    // can reach this object any more.
    private nonisolated(unsafe) var process: Process?
    private var stopping = false
    private nonisolated(unsafe) var quitObserver: NSObjectProtocol?

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

    var isRunning: Bool { process?.isRunning ?? false }

    init() {
        // A child left speaking after VoiceChat quits would be an orphan
        // nobody can stop from here.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        process?.terminate()
    }

    func speak(_ text: String, voice: TalkingHeadVoice) {
        stop()
        stopping = false

        guard let url = Self.executableURL else {
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
