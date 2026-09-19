import Foundation

// Spec §4.4 — result rendering for the `converse` tool.
//
// Every result is returned as both `structuredContent` and a human-readable
// text mirror, because many hosts surface only the text block to the model
// (R-MCP-4).

public enum ConverseStatus: String, Sendable, Codable {
    case prompt, waiting, ended
}

public struct ConverseResult: Sendable, Equatable {
    public var status: ConverseStatus
    public var userMessage: String?
    public var turn: Int?
    public var continuation: String?
    public var reason: String?
    /// Prepended to the text mirror when the model skipped a step (R-MCP-8).
    public var note: String?

    public init(status: ConverseStatus, userMessage: String? = nil, turn: Int? = nil,
                continuation: String? = nil, reason: String? = nil, note: String? = nil) {
        self.status = status
        self.userMessage = userMessage
        self.turn = turn
        self.continuation = continuation
        self.reason = reason
        self.note = note
    }

    public static func prompt(_ message: String, turn: Int, note: String? = nil) -> Self {
        .init(status: .prompt, userMessage: message, turn: turn, note: note)
    }
    public static func waiting(continuation: String) -> Self {
        .init(status: .waiting, continuation: continuation)
    }
    public static func ended(reason: EndReason) -> Self {
        .init(status: .ended, reason: reason.rawValue)
    }

    /// The `structuredContent` payload, matching the tool's `outputSchema`.
    public var structuredContent: [String: Any] {
        var out: [String: Any] = ["status": status.rawValue]
        if let userMessage { out["user_message"] = userMessage }
        if let turn { out["turn"] = turn }
        if let continuation { out["continuation"] = continuation }
        if let reason { out["reason"] = reason }
        return out
    }

    /// The text mirror. This is what most hosts actually show the model, so it
    /// carries the loop instructions.
    public var text: String {
        var body: String
        switch status {
        case .prompt:
            body = """
            The user said:

            <user_message>
            \(Self.neutralise(userMessage ?? ""))
            </user_message>

            Answer this, then call `converse` again with your answer in `message` to continue.
            """
        case .waiting:
            body = """
            The user is still composing their message. The conversation window is open and waiting.

            Call `converse` again immediately with continuation="\(continuation ?? "")" and no `message`.
            Do not reply to the user and do not stop.
            """
        case .ended:
            body = """
            The conversation has ended (reason: \(reason ?? "unknown")).

            Reply to the user with exactly: Conversation ended.
            Do not call `converse` again.
            """
        }
        if let note { body = note + "\n\n" + body }
        return body
    }

    /// R-MCP-9 — a spoken transcript must not be able to close the delimiter
    /// that contains it.
    static func neutralise(_ s: String) -> String {
        s.replacingOccurrences(of: "</user_message", with: "<\\/user_message",
                               options: [.caseInsensitive])
    }
}
