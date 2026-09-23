import Foundation

// Spec §3 — VCP, the daemon ⇄ MCP server control protocol.
// JSON-RPC 2.0 over an AF_UNIX stream, one object per line (R-VCP-2).

public enum VCP {
    /// R-VCP-4 — version negotiation is exact-match.
    public static let version = 1

    /// R-VCP-2 — a longer line is rejected and the connection closed.
    public static let maxLineBytes = 16 * 1024 * 1024

    public static func defaultSocketURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VOICECHAT_SOCKET"] {
            return URL(fileURLWithPath: override)
        }
        return supportDirectoryURL().appendingPathComponent("daemon.sock")
    }

    public static func supportDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceChat", isDirectory: true)
    }
}

// MARK: - Methods

public enum VCPMethod: String, Sendable, Codable {
    // Client → daemon (requests)
    case hello
    case sessionOpen = "session.open"
    case turnAwait = "turn.await"
    case turnCancel = "turn.cancel"
    case sessionClose = "session.close"
    case sessionRoots = "session.roots"
    case ping

    // Daemon → client (notifications)
    case sessionEnded = "session.ended"
    case turnProgress = "turn.progress"
}

// MARK: - Errors (§3.6)

public struct VCPError: Error, Sendable, Codable, Equatable {
    public var code: Int
    public var message: String
    public var data: ErrorData?

    public struct ErrorData: Sendable, Codable, Equatable {
        public var currentTurnId: String?
        public var phase: String?
        public var accepted: [Int]?

        public init(currentTurnId: String? = nil, phase: String? = nil, accepted: [Int]? = nil) {
            self.currentTurnId = currentTurnId
            self.phase = phase
            self.accepted = accepted
        }
    }

    public init(code: Int, message: String, data: ErrorData? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public enum Code {
        public static let turnOutOfSync = -32010
        public static let turnAlreadyAwaited = -32011
        public static let unknownSession = -32012
        public static let vcpVersionUnsupported = -32013
        public static let sessionLimitReached = -32014
        public static let daemonShuttingDown = -32015
        public static let debateSeatUnavailable = -32016
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
    }

    public static func turnOutOfSync(currentTurnId: String, phase: String) -> VCPError {
        VCPError(code: Code.turnOutOfSync, message: "turn_out_of_sync",
                 data: .init(currentTurnId: currentTurnId, phase: phase))
    }

    public static let turnAlreadyAwaited = VCPError(code: Code.turnAlreadyAwaited, message: "turn_already_awaited")
    public static let unknownSession = VCPError(code: Code.unknownSession, message: "unknown_session")
    public static let daemonShuttingDown = VCPError(code: Code.daemonShuttingDown, message: "daemon_shutting_down")

    /// The seat was taken, or the room does not exist. `message` is written to
    /// be read by the model as-is.
    public static func debateSeatUnavailable(_ message: String) -> VCPError {
        VCPError(code: Code.debateSeatUnavailable, message: message)
    }

    public static func versionUnsupported(accepted: [Int]) -> VCPError {
        VCPError(code: Code.vcpVersionUnsupported, message: "vcp_version_unsupported",
                 data: .init(accepted: accepted))
    }

    /// R-VCP-16 — every VCP error surfaced to the model is an actionable
    /// sentence, not a code.
    public var actionableSentence: String {
        switch code {
        case Code.turnOutOfSync:
            return "The conversation has moved on (VoiceChat is on turn \(data?.currentTurnId ?? "?"), phase \(data?.phase ?? "?")). Stop calling converse and tell the user what happened."
        case Code.turnAlreadyAwaited:
            return "A turn is already in progress for this conversation. Stop calling converse."
        case Code.unknownSession:
            return "The conversation window is gone. Stop calling converse and tell the user it ended."
        case Code.vcpVersionUnsupported:
            let accepted = (data?.accepted ?? []).map(String.init).joined(separator: ", ")
            return "VoiceChat speaks protocol version(s) \(accepted) but this MCP server expects \(VCP.version). Tell the user to reinstall VoiceChat, then stop."
        case Code.sessionLimitReached:
            return "VoiceChat declined to open another conversation window. Tell the user to close an existing one, then stop."
        case Code.daemonShuttingDown:
            return "VoiceChat is quitting. Tell the user to relaunch it, then stop."
        case Code.debateSeatUnavailable:
            return message
        default:
            return "VoiceChat reported an error: \(message). Tell the user and stop."
        }
    }
}

// MARK: - Payloads (§3.3, §3.4)

public struct HelloParams: Sendable, Codable, Equatable {
    public struct Peer: Sendable, Codable, Equatable {
        public var name: String
        public var version: String
        public var pid: Int32?
        public init(name: String, version: String, pid: Int32? = nil) {
            self.name = name; self.version = version; self.pid = pid
        }
    }
    public var vcpVersion: Int
    public var client: Peer
    public var host: Peer?

    public init(vcpVersion: Int = VCP.version, client: Peer, host: Peer? = nil) {
        self.vcpVersion = vcpVersion; self.client = client; self.host = host
    }
}

public struct HelloResult: Sendable, Codable, Equatable {
    public var vcpVersion: Int
    public var daemonVersion: String
    public init(vcpVersion: Int = VCP.version, daemonVersion: String) {
        self.vcpVersion = vcpVersion; self.daemonVersion = daemonVersion
    }
}

public struct SessionOpenParams: Sendable, Codable, Equatable {
    public var sessionId: String
    public var title: String?
    public var host: String?
    public var cwd: String?
    /// The model driving the first `converse` call, if the caller supplied one.
    public var model: String?
    /// The debate seat this client is claiming, if any.
    public var debate: DebateJoin?
    public init(sessionId: String, title: String? = nil, host: String? = nil, cwd: String? = nil,
                model: String? = nil, debate: DebateJoin? = nil) {
        self.sessionId = sessionId; self.title = title; self.host = host; self.cwd = cwd
        self.model = model; self.debate = debate
    }
}

public struct SessionOpenResult: Sendable, Codable, Equatable {
    public var sessionId: String
    public var turnId: String
    public init(sessionId: String, turnId: String) {
        self.sessionId = sessionId; self.turnId = turnId
    }
}

public struct AssistantMessage: Sendable, Codable, Equatable {
    public var markdown: String
    public init(markdown: String) { self.markdown = markdown }
}

public struct TurnAwaitParams: Sendable, Codable, Equatable {
    public var sessionId: String
    public var turnId: String
    /// `nil` on the first turn and when resuming a bounded wait (R-VCP-8).
    public var assistant: AssistantMessage?
    public var waitMs: Int
    /// The model driving this call, if the caller supplied one. May change turn to turn.
    public var model: String?

    public init(sessionId: String, turnId: String, assistant: AssistantMessage?, waitMs: Int,
                model: String? = nil) {
        self.sessionId = sessionId; self.turnId = turnId
        self.assistant = assistant; self.waitMs = waitMs
        self.model = model
    }
}

public struct TurnAwaitResult: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        case prompt, pending, ended
    }
    public var outcome: Outcome
    public var turnId: String?
    /// R-VCP-12 — the turn the client must quote on its next `turn.await`.
    public var nextTurnId: String?
    public var markdown: String?
    public var reason: EndReason?

    public init(outcome: Outcome, turnId: String? = nil, nextTurnId: String? = nil,
                markdown: String? = nil, reason: EndReason? = nil) {
        self.outcome = outcome; self.turnId = turnId; self.nextTurnId = nextTurnId
        self.markdown = markdown; self.reason = reason
    }

    public static func prompt(turnId: String, nextTurnId: String, markdown: String) -> Self {
        .init(outcome: .prompt, turnId: turnId, nextTurnId: nextTurnId, markdown: markdown)
    }
    public static func pending(turnId: String) -> Self {
        .init(outcome: .pending, turnId: turnId)
    }
    public static func ended(_ reason: EndReason) -> Self {
        .init(outcome: .ended, reason: reason)
    }
}

public struct TurnRefParams: Sendable, Codable, Equatable {
    public var sessionId: String
    public var turnId: String
    public init(sessionId: String, turnId: String) {
        self.sessionId = sessionId; self.turnId = turnId
    }
}

/// The MCP roots the host reported for a session. Sent after the session
/// opens, and again whenever the host says its roots changed.
public struct SessionRootsParams: Sendable, Codable, Equatable {
    public var sessionId: String
    public var roots: [WorkspaceRoot]
    public init(sessionId: String, roots: [WorkspaceRoot]) {
        self.sessionId = sessionId; self.roots = roots
    }
}

public struct SessionCloseParams: Sendable, Codable, Equatable {
    public var sessionId: String
    public var reason: EndReason
    public init(sessionId: String, reason: EndReason) {
        self.sessionId = sessionId; self.reason = reason
    }
}

public struct SessionEndedParams: Sendable, Codable, Equatable {
    public var sessionId: String
    public var reason: EndReason
    public init(sessionId: String, reason: EndReason) {
        self.sessionId = sessionId; self.reason = reason
    }
}

public struct TurnProgressParams: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case composing, dictating, speaking, idle
    }
    public var sessionId: String
    public var turnId: String
    public var phase: Phase
    public var detail: String?

    public init(sessionId: String, turnId: String, phase: Phase, detail: String? = nil) {
        self.sessionId = sessionId; self.turnId = turnId
        self.phase = phase; self.detail = detail
    }

    /// The text surfaced as an MCP progress notification message (R-MCP-11).
    public var progressMessage: String {
        switch phase {
        case .composing: return detail ?? "User is composing…"
        case .dictating: return detail ?? "Listening…"
        case .speaking:  return detail ?? "Speaking the response…"
        case .idle:      return detail ?? "Waiting…"
        }
    }
}

public struct EmptyPayload: Sendable, Codable, Equatable {
    public init() {}
}
