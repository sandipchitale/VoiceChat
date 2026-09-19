import Foundation

// Spec §3.4 — the daemon's per-session turn bookkeeping.
//
// This is where R-VCP-7 … R-VCP-12 are enforced. It is the reason the MCP
// server and the window cannot disagree about whose turn it is (goal G2), and
// it is deliberately free of any UI so the rules can be tested directly.

public actor TurnCoordinator {

    public enum Phase: String, Sendable {
        case composing, submitted, responding, ended
    }

    public private(set) var phase: Phase = .composing
    private var turns: TurnSequence
    /// R-VCP-9 — a response is written to a turn exactly once.
    private var turnsWithResponse: Set<String> = []
    private var waiter: CheckedContinuation<TurnAwaitResult, Never>?
    private var waitingTurnId: String?
    private var timeoutTask: Task<Void, Never>?
    private var endedReason: EndReason?

    public init(startingAt n: Int = 1) {
        self.turns = TurnSequence(startingAt: n)
    }

    public var currentTurnId: String { turns.current }
    public var isAwaiting: Bool { waiter != nil }

    // MARK: Called by the VCP peer

    /// One bounded wait. Returns exactly one of prompt / pending / ended.
    public func awaitTurn(
        _ params: TurnAwaitParams,
        display: @Sendable (String) -> Void
    ) async throws -> TurnAwaitResult {

        if let endedReason { return .ended(endedReason) }

        // R-VCP-10
        guard waiter == nil else { throw VCPError.turnAlreadyAwaited }

        // R-VCP-7 — the turn id is the synchronisation token.
        guard params.turnId == turns.current else {
            throw VCPError.turnOutOfSync(currentTurnId: turns.current, phase: phase.rawValue)
        }

        if let assistant = params.assistant {
            // R-VCP-9
            guard !turnsWithResponse.contains(params.turnId) else {
                throw VCPError.turnOutOfSync(currentTurnId: turns.current, phase: phase.rawValue)
            }
            turnsWithResponse.insert(params.turnId)
            phase = .responding
            display(assistant.markdown)
        }
        // R-VCP-8 — `assistant == nil` simply resumes waiting. Nothing is
        // displayed and nothing changes on screen (R-MCP-13).

        // A prompt that arrived before the server started waiting is delivered
        // immediately, rather than sitting idle until the next bounded wait.
        if let queued = queuedPrompt {
            queuedPrompt = nil
            let completed = turns.current
            let next = turns.advance()
            phase = .composing
            return .prompt(turnId: completed, nextTurnId: next, markdown: queued)
        }

        let turnId = params.turnId
        waitingTurnId = turnId

        let waitMs = params.waitMs
        return await withCheckedContinuation { continuation in
            waiter = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(waitMs))
                guard !Task.isCancelled else { return }
                await self?.timeOut(turnId: turnId)
            }
        }
    }

    public func cancelTurn(_ turnId: String) {
        guard turnId == turns.current else { return }
        resume(with: .ended(.hostCancelled))
        endedReason = .hostCancelled
        phase = .ended
    }

    // MARK: Called by the session / window

    /// The person pressed Send (or said "Send prompt"). R-VCP-12 advances the
    /// turn atomically before the result is handed back.
    public func submitPrompt(_ markdown: String) {
        guard waiter != nil, endedReason == nil else { return }
        let completed = turns.current
        let next = turns.advance()
        phase = .composing
        resume(with: .prompt(turnId: completed, nextTurnId: next, markdown: markdown))
    }

    /// Row 2 of §5.2 reached the daemon before the MCP server was waiting: hold
    /// the prompt until the next `turn.await` arrives.
    public func queuePrompt(_ markdown: String) {
        if waiter != nil { submitPrompt(markdown); return }
        queuedPrompt = markdown
    }
    private var queuedPrompt: String?

    public func end(_ reason: EndReason) {
        guard endedReason == nil else { return }
        endedReason = reason
        phase = .ended
        resume(with: .ended(reason))
    }

    public func markSubmitted() {
        guard phase != .ended else { return }
        phase = .submitted
    }

    // MARK: Internals

    private func timeOut(turnId: String) {
        // R-VCP-11 — a bounded wait expiring carries no prompt and does not
        // advance the turn.
        guard waitingTurnId == turnId, waiter != nil else { return }
        resume(with: .pending(turnId: turnId))
    }

    private func resume(with result: TurnAwaitResult) {
        timeoutTask?.cancel()
        timeoutTask = nil
        waitingTurnId = nil
        guard let continuation = waiter else { return }
        waiter = nil
        continuation.resume(returning: result)
    }

    /// Drain a prompt that arrived before the server started waiting.
    public func takeQueuedPrompt() -> String? {
        defer { queuedPrompt = nil }
        return queuedPrompt
    }
}
