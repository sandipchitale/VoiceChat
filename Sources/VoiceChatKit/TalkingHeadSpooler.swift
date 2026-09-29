import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Spec §9.5 — a minimal client for Talking Head's speech spooler socket.
//
// It mirrors Talking Head's own `MCPTools/Spooler.swift` (newline-delimited
// JSON objects keyed by "type"), but is self-contained: VoiceChat depends on
// nothing from Talking Head, and an older Talking Head (no socket, or no
// presence) simply means falling back to `th`.
//
//   → {"type":"speak","text":"…","voice":"male","alwaysOnTop":true}
//   ← {"type":"queued"} {"type":"started"} then {"type":"finished"|"stopped"|"error","message":…}
//   → {"type":"presence","state":"listening"|"thinking"|"none","voice":"female","pulse":"nod"?}
//   ← {"type":"presence"}   (an older Talking Head answers {"type":"error",…})
//
// Closing a connection takes back what it asked for: its speech, its presence.

public enum TalkingHeadSpooler {
    public static let socketEnvironmentKey = "TALKINGHEAD_SPOOLER_SOCKET"

    /// ~/Library/Application Support/TalkingHead/speech.sock, or the
    /// `TALKINGHEAD_SPOOLER_SOCKET` override (as Talking Head itself reads it).
    public static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment[socketEnvironmentKey], !path.isEmpty {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TalkingHead/speech.sock").path
    }

    /// `R-TTS-19` — how long the first reply may take before Talking Head is
    /// treated as absent.
    public static let replyTimeout: TimeInterval = 0.3
}

/// A message to the spooler.
public struct TalkingHeadSpoolerRequest: Codable, Sendable, Equatable {
    public var type: String
    public var text: String?
    public var voice: String?
    public var alwaysOnTop: Bool?
    public var state: String?
    public var pulse: String?

    public static func speak(_ text: String, voice: String) -> TalkingHeadSpoolerRequest {
        TalkingHeadSpoolerRequest(type: "speak", text: text, voice: voice, alwaysOnTop: true)
    }

    public static func presence(_ presence: TalkingHeadPresence, voice: String? = nil,
                                nod: Bool = false) -> TalkingHeadSpoolerRequest {
        TalkingHeadSpoolerRequest(type: "presence", voice: voice, state: presence.rawValue,
                                  pulse: nod ? "nod" : nil)
    }

    /// One line of the protocol, newline included.
    public var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(self)) ?? Data()) + Data([0x0A])
    }
}

/// A message from the spooler. Unknown types decode, with a nil `kind`, so a
/// newer Talking Head's events are skipped rather than breaking the client.
public struct TalkingHeadSpoolerEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Sendable { case queued, started, finished, stopped, error, presence }

    public var type: String
    public var message: String?

    public init(type: String, message: String? = nil) {
        self.type = type
        self.message = message
    }

    public var kind: Kind? { Kind(rawValue: type) }

    /// The end of a speech: no more events follow for it.
    public var isFinal: Bool { kind == .finished || kind == .stopped || kind == .error }
}

/// One connection to the spooler. Reading is blocking and meant for one
/// background thread at a time; `send` and `close` may be called from any
/// thread. `close` wakes a blocked reader, which then sees the end.
public final class TalkingHeadSpoolerConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false
    // Touched only by the (single) reader.
    private var framer = LineFramer()
    private var lines: [Data] = []

    private init(fd: Int32) { self.fd = fd }

    deinit { Darwin.close(fd) }

    /// Connects, or returns nil when nothing is listening at `path` (Talking
    /// Head isn't running, or is too old to have a spooler) or the listener
    /// isn't this user.
    public static func open(at path: String = TalkingHeadSpooler.socketPath) -> TalkingHeadSpoolerConnection? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Speech goes only to a Talking Head run by this same user.
        var uid: uid_t = 0, gid: gid_t = 0
        guard connected == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(fd)
            return nil
        }
        return TalkingHeadSpoolerConnection(fd: fd)
    }

    /// Sends one message; false if the connection is closed or broken.
    @discardableResult
    public func send(_ request: TalkingHeadSpoolerRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return false }
        return request.line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// The next event, waiting at most `timeout` seconds (for ever when nil).
    /// Nil on timeout, when the connection ends, or after `close`.
    public func nextEvent(timeout: TimeInterval? = nil) -> TalkingHeadSpoolerEvent? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            while !lines.isEmpty {
                let line = lines.removeFirst()
                if let event = try? JSONDecoder().decode(TalkingHeadSpoolerEvent.self, from: line) {
                    return event
                }
            }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32((remaining * 1000).rounded(.up)))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { return nil }
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, let received = try? framer.append(Data(buffer[0..<count])) else { return nil }
            lines.append(contentsOf: received)
        }
    }

    /// Ends the connection: Talking Head takes back its speech and presence.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
    }
}
