import Foundation

// Spec §4 — the `converse` tool's conversation loop, extracted from the
// original stdio-only `ConverseRuntime` so every transport (stdio, Streamable
// HTTP, …) shares one implementation of the tricky part: the turn/continuation
// state machine, including the restart-after-`ended` behaviour of R-MCP-17.
//
// A `ConverseSessionGateway` is the one seam between this state machine and
// however a given transport actually reaches a VoiceChat session — over VCP
// for stdio, or directly in-process for a daemon-hosted HTTP transport.

/// How a `ConverseSessionEngine` reaches an actual VoiceChat session. Each
/// transport supplies its own conformance; the engine itself never depends on
/// VCP, a socket, or AppKit.
public protocol ConverseSessionGateway: Sendable {
    /// Opens a fresh session. `onEnded`/`onProgress` fire out-of-band —
    /// independent of any in-flight `awaitTurn` call — whenever the session
    /// ends or its phase changes, e.g. the window closes with nothing
    /// currently blocked in `awaitTurn`.
    func openSession(
        onEnded: @escaping @Sendable (EndReason) async -> Void,
        onProgress: @escaping @Sendable (TurnProgressParams.Phase) async -> Void
    ) async throws -> (sessionId: String, firstTurnId: String)

    func awaitTurn(
        sessionId: String, turnId: String,
        assistant: AssistantMessage?, waitMs: Int
    ) async throws -> TurnAwaitResult

    func closeSession(sessionId: String, reason: EndReason) async

    /// Drops whatever session state is held, without notifying the far end —
    /// called when a conversation has already ended and the engine is about
    /// to open a brand new one (R-MCP-17). The VCP gateway closes its stale
    /// socket here; an in-process gateway has nothing to do.
    func discardSession() async
}

public extension ConverseSessionGateway {
    func discardSession() async {}
}

public enum ConverseEngineError: Error, Sendable {
    case bothArguments
    case badContinuation

    public var actionableSentence: String {
        switch self {
        case .bothArguments:
            return "Pass either `message` or `continuation`, never both. Call `converse` again with just one of them."
        case .badContinuation:
            return "That continuation token is not valid for this conversation. Stop calling converse and tell the user."
        }
    }
}

public actor ConverseSessionEngine<Gateway: ConverseSessionGateway> {
    private let gateway: Gateway
    private let waitMs: Int
    private let signer = ContinuationSigner()

    private var sessionId: String?
    private var turns = TurnSequence()
    private var turnNumber = 0
    private var pendingToken: ContinuationToken?
    private var endedReason: EndReason?
    private var lastPhase: TurnProgressParams.Phase = .idle

    public init(gateway: Gateway, waitMs: Int) {
        self.gateway = gateway
        self.waitMs = waitMs
    }

    public var currentPhaseMessage: String {
        TurnProgressParams(sessionId: sessionId ?? "", turnId: turns.current,
                           phase: lastPhase).progressMessage
    }

    // MARK: The tool body

    public func converse(message: String?, continuation: String?) async throws -> ConverseResult {
        // R-MCP-7
        if message != nil, continuation != nil { throw ConverseEngineError.bothArguments }

        if endedReason != nil {
            if message == nil, continuation == nil {
                // R-MCP-17 — a bare "start" call after a previous conversation
                // ended begins a brand new one instead of repeating the old
                // outcome forever.
                await startFresh()
            } else {
                return .ended(reason: endedReason!)
            }
        }

        var note: String?

        if sessionId == nil {
            try await openSession()
            // R-MCP-8 — the model skipped step 1. Open the window anyway and
            // say plainly that the reply was dropped, rather than showing a
            // response to a prompt that was never given.
            if message != nil {
                note = "Note: you supplied `message` on the first call, before the user had said anything. It was not shown. The conversation has just started."
            }
        }

        if let continuation {
            guard signer.verify(continuation, expecting: pendingToken) != nil else {
                throw ConverseEngineError.badContinuation
            }
        }

        let assistant: AssistantMessage? = (continuation == nil && note == nil)
            ? message.map(AssistantMessage.init(markdown:))
            : nil

        return try await awaitTurn(assistant: assistant, note: note)
    }

    // MARK: Session lifecycle

    private func openSession() async throws {
        let (id, firstTurnId) = try await gateway.openSession(
            onEnded: { [weak self] reason in await self?.noteEnded(reason) },
            onProgress: { [weak self] phase in await self?.noteProgress(phase) }
        )
        sessionId = id
        turns = TurnSequence(startingAt: TurnSequence.index(of: firstTurnId) ?? 1)
        turnNumber = 1
    }

    private func noteEnded(_ reason: EndReason) { endedReason = reason }
    private func noteProgress(_ phase: TurnProgressParams.Phase) { lastPhase = phase }

    // MARK: One bounded wait

    private func awaitTurn(assistant: AssistantMessage?, note: String?) async throws -> ConverseResult {
        guard let sessionId else {
            preconditionFailure("awaitTurn called before a session was opened")
        }
        let result = try await gateway.awaitTurn(sessionId: sessionId, turnId: turns.current,
                                                 assistant: assistant, waitMs: waitMs)

        switch result.outcome {
        case .prompt:
            // R-VCP-12 — adopt the daemon's next turn id; it is authoritative.
            if let next = result.nextTurnId, let n = TurnSequence.index(of: next) {
                turns = TurnSequence(startingAt: n)
            } else {
                _ = turns.advance()
            }
            turnNumber += 1
            pendingToken = nil
            return .prompt(result.markdown ?? "", turn: turnNumber - 1, note: note)

        case .pending:
            // R-MCP-13 — nothing has changed on screen; hand back a resume token.
            let token = ContinuationToken(sessionId: sessionId, turnId: turns.current)
            pendingToken = token
            return .waiting(continuation: signer.sign(token))

        case .ended:
            let reason = result.reason ?? .userEnded
            endedReason = reason
            return .ended(reason: reason)
        }
    }

    // MARK: Starting over

    /// Discards the ended conversation's session state so the next
    /// `openSession()` behaves exactly as it would on first use.
    private func startFresh() async {
        await gateway.discardSession()
        sessionId = nil
        turns = TurnSequence()
        turnNumber = 0
        pendingToken = nil
        endedReason = nil
        lastPhase = .idle
    }

    // MARK: Shutdown

    public func shutdown(reason: EndReason) async {
        guard let sessionId else { return }
        await gateway.closeSession(sessionId: sessionId, reason: reason)
    }
}
