import Foundation
import MCP

// Spec §4.2 — the `converse` tool's contract, shared verbatim by every
// transport (stdio, Streamable HTTP, …) so they cannot drift apart.

public enum ConverseTool {
    public static let name = "converse"

    public static let description = """
    Hold a spoken, multi-turn conversation with the user in a dedicated window on their Mac. The user \
    speaks or types; you reply; your reply is read aloud to them; they answer. Use this when the user \
    asks to talk, to use voice, or to have a back-and-forth conversation.

    How to run the conversation:

    1. Start by calling `converse` with no arguments. A window opens on the user's screen.
    2. Each call returns a `status`. Act on it:
       - status "prompt" — `user_message` is what the user just said. Answer it, then call `converse` \
    again with your answer in `message`. Your answer is displayed and read aloud.
       - status "waiting" — the user is still composing. Call `converse` again IMMEDIATELY, passing \
    back the `continuation` token unchanged and NO `message`. Do not write anything to the user, do not \
    do other work, and do not stop. This result only means the window is still open and the user has \
    not finished speaking yet.
       - status "ended" — the user closed the conversation. Reply with exactly "Conversation ended." \
    and do not call `converse` again.
    3. Keep looping until you get "ended". The conversation is over only when the user ends it.

    Rules:

    - Never invent, guess, or summarise a user turn. The only thing the user said is what arrives in \
    `user_message`.
    - Write `message` as if speaking it aloud, because it will be. Prefer short sentences. Markdown \
    formatting is rendered in the window; code blocks are shown but not read aloud.
    - Do not ask the user to type in this chat while a conversation is open — they are looking at the \
    VoiceChat window.
    - If a call returns an error, report it to the user in plain language and stop; do not retry in a \
    loop.
    - Optionally pass `model` on every call with the name of the model you are running as. The window \
    shows it next to the name of the app you are running in.

    Debates:

    - If the user asks you to join a debate and gives you an id, pass `debate_id` and `side` on your \
    FIRST call only, with no `message`. You take that seat; another AI takes the other one. Everything \
    after that is the ordinary loop above — never pass them again.
    - In a debate, `user_message` is your opponent's latest statement, and your `message` is your reply \
    to it. A line starting "> Moderator:" is from the human watching; do as it says.
    - "waiting" happens often and repeatedly in a debate, because your opponent may take minutes to \
    answer and the human passes each statement across by hand. Keep calling `converse` with the \
    continuation. Do not stop, do not report progress, and do not do other work in between.
    """

    public static let inputSchema: Value = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "description": .string("Your reply to the user, in Markdown. Omit this only on your very first call (which opens the conversation) and when resuming after a 'waiting' result."),
            ]),
            "continuation": .object([
                "type": .string("string"),
                "description": .string("Opaque token. Supply it, unchanged and alone, only when a previous result had status 'waiting'."),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional. The name of the model driving this call (e.g. 'claude-sonnet-5'). Shown in the window; may change between calls."),
            ]),
            "debate_id": .object([
                "type": .string("string"),
                "description": .string("The id of a debate to join, e.g. 'owl-42'. First call only, and only when the user gave you one."),
            ]),
            "side": .object([
                "type": .string("string"),
                "description": .string("Which seat of that debate to take, e.g. 'for'. Goes with debate_id, on the first call only."),
            ]),
        ]),
    ])

    public static let outputSchema: Value = .object([
        "type": .string("object"),
        "required": .array([.string("status")]),
        "properties": .object([
            "status": .object([
                "type": .string("string"),
                "enum": .array([.string("prompt"), .string("waiting"), .string("ended")]),
            ]),
            "user_message": .object(["type": .string("string")]),
            "turn": .object(["type": .string("integer")]),
            "continuation": .object(["type": .string("string")]),
            "reason": .object(["type": .string("string")]),
        ]),
    ])

    public static func tool() -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: .init(
                title: "Voice conversation",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        )
    }

    /// The debate seat a call is claiming, read from the two optional
    /// arguments above. Lives here, next to the schema that declares them, so
    /// the transports cannot disagree about their names.
    public static func debateJoin(from arguments: [String: Value]?) -> DebateJoin? {
        guard case .string(let id)? = arguments?["debate_id"], !id.isEmpty else { return nil }
        let seat: String = if case .string(let s)? = arguments?["side"] { s } else { "" }
        return DebateJoin(roomID: id, seat: seat)
    }

    public static func structuredContent(_ result: ConverseResult) -> Value {
        var fields: [String: Value] = ["status": .string(result.status.rawValue)]
        if let m = result.userMessage { fields["user_message"] = .string(m) }
        if let t = result.turn { fields["turn"] = .int(t) }
        if let c = result.continuation { fields["continuation"] = .string(c) }
        if let r = result.reason { fields["reason"] = .string(r) }
        return .object(fields)
    }

    /// R-MCP-11 layer A — keep the host's own timer alive while a call blocks.
    /// Every transport needs the identical 5s ticker; only how it reaches the
    /// current phase (`phaseMessage`) differs.
    public static func startProgressTicker(
        server: Server,
        progressToken: ProgressToken?,
        phaseMessage: @escaping @Sendable () async -> String
    ) -> Task<Void, Never> {
        Task {
            guard let progressToken else { return }
            var n = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                n += 1
                let text = await phaseMessage()
                try? await server.notify(
                    ProgressNotification.message(
                        .init(progressToken: progressToken, progress: n, message: text)))
            }
        }
    }
}
