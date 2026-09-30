import AppKit
import Foundation
import VoiceChatKit

// Spec §17, R-DEB-11 — finding and running the command-line clients the New
// Debate dialog offers (`DebateClient`).

/// The PATH of the person's login shell. A GUI app is started with a minimal
/// PATH, so `claude`, `agy` and `codex` (and the `node` Codex needs) would not
/// be found without it.
enum ShellPath {
    /// Where these tools usually live, added in case the shell can't be asked.
    private static let usualDirectories = [
        "~/.local/bin", "~/.npm-global/bin", "~/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
    ].map { ($0 as NSString).expandingTildeInPath }

    @MainActor private static var cached: String?

    /// Asks the login shell once (interactive too, since many people set PATH
    /// in `.zshrc`), with a 3-second limit, then remembers the answer.
    @MainActor static func login() async -> String {
        if let cached { return cached }
        let value = await Task.detached { resolve() }.value
        cached = value
        return value
    }

    nonisolated private static func resolve() -> String {
        let marker = "__VOICECHAT_PATH__"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var shellPath = ""
        if (try? process.run()) != nil {
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            if done.wait(timeout: .now() + 3) == .timedOut { process.terminate() }
            let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            let parts = text.components(separatedBy: marker)
            if parts.count >= 3 { shellPath = parts[1] }
        }
        var directories = shellPath.split(separator: ":").map(String.init)
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += usualDirectories
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}

/// Which clients are installed, and where.
enum DebateClientFinder {
    @MainActor static func available() async -> [DebateClient: URL] {
        let path = await ShellPath.login()
        var found: [DebateClient: URL] = [:]
        for client in DebateClient.allCases {
            if let executable = DebateClient.find(client.executableName, onPath: path) {
                found[client] = URL(fileURLWithPath: executable)
            }
        }
        return found
    }
}

/// Starts the clients chosen for a debate's seats and stops them when the
/// debate is over. Each runs in an empty folder for its debate,
/// `~/Library/Application Support/VoiceChat/debates/<room>/`, with its output
/// in `<seat>-<client>.log` there.
@MainActor
public final class DebateClientLauncher {
    public static let shared = DebateClientLauncher()

    private struct Running {
        let seat: String
        let client: DebateClient
        let process: Process
        let log: URL
    }

    private var running: [String: [Running]] = [:]
    /// Rooms being stopped on purpose, whose clients' exits aren't reported.
    private var stopping: Set<String> = []

    /// Says whether a seat is still free, to tell a client that failed to join
    /// from one that finished after the debate.
    public var isSeatFree: ((_ roomID: String, _ seat: String) -> Bool)?

    init() {}

    /// VoiceChat's own stdio MCP server, for the proposed commands.
    public static var mcpServerPath: String {
        Bundle.main.url(forAuxiliaryExecutable: "voicechat-mcp")?.path
            ?? "/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp"
    }

    /// Runs `command` (the person's, as edited in the New Debate dialog) to take
    /// `seat` of `room` with `client`. The shell runs it with the login-shell
    /// PATH, and the seat's join instruction in `$VOICECHAT_JOIN`.
    public func launch(_ client: DebateClient, command: String, seat: DebateSeat, room: DebateRoom) {
        Task {
            let path = await ShellPath.login()
            self.start(client, command: command, path: path, seat: seat, room: room)
        }
    }

    private func start(_ client: DebateClient, command: String, path: String,
                       seat: DebateSeat, room: DebateRoom) {
        let files = FileManager.default
        let folder = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceChat/debates/\(room.id)", isDirectory: true)
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("\(seat.key)-\(client.rawValue).log")
        files.createFile(atPath: log.path, contents: nil)

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment[DebateClient.instructionVariable] = room.joinInstruction(for: seat)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        let roomID = room.id
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(roomID: roomID, seat: seat.key, client: client, status: status, log: log) }
        }
        do {
            // The command heads the log, so a failure can be matched to what ran.
            try? FileHandle(forWritingTo: log).write(Data("$ \(command)\n\n".utf8))
            if let handle = process.standardOutput as? FileHandle { handle.seekToEndOfFile() }
            try process.run()
            running[room.id, default: []].append(Running(seat: seat.key, client: client, process: process, log: log))
        } catch {
            report("\(client.displayName) couldn't start: \(error.localizedDescription)")
        }
    }

    /// Stops every client started for `roomID`.
    public func stop(roomID: String) {
        guard let clients = running.removeValue(forKey: roomID) else { return }
        stopping.insert(roomID)
        for client in clients where client.process.isRunning { client.process.terminate() }
    }

    /// Stops the clients of rooms that no longer exist.
    public func stopAll(except liveRooms: Set<String> = []) {
        for roomID in running.keys where !liveRooms.contains(roomID) { stop(roomID: roomID) }
    }

    private func ended(roomID: String, seat: String, client: DebateClient, status: Int32, log: URL) {
        running[roomID]?.removeAll { $0.seat == seat && $0.client == client }
        if running[roomID]?.isEmpty == true { running[roomID] = nil }
        guard !stopping.contains(roomID) else { return }
        // A client that never took its seat failed to join: say so, rather than
        // leave the debate waiting for it in silence.
        if isSeatFree?(roomID, seat) == true {
            report("""
                \(client.displayName) exited (status \(status)) without taking the "\(seat)" seat of \
                debate \(roomID). Its output is in \(log.path).
                """)
        }
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "A debater couldn't join"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
