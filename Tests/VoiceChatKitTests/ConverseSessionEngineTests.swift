import Foundation
import Testing
@testable import VoiceChatKit

// Spec §4 — `ConverseSessionEngine` is the shared state machine behind the
// `converse` tool, extracted so both the stdio and Streamable HTTP
// transports drive one implementation. `MockGateway` stands in for either
// transport's real gateway, so the whole loop — including R-MCP-17's
// restart-after-`ended` behaviour — is testable with no daemon and no socket.

private struct DummyError: Error, Equatable {}

private actor MockGateway: ConverseSessionGateway {
    private(set) var openSessionCallCount = 0
    private(set) var closeCalls: [(sessionId: String, reason: EndReason)] = []
    private(set) var discardCallCount = 0
    private(set) var awaitCalls: [(sessionId: String, turnId: String, assistant: AssistantMessage?)] = []

    private var results: [TurnAwaitResult]
    private var awaitError: Error?
    private var onEnded: (@Sendable (EndReason) async -> Void)?
    private var onProgress: (@Sendable (TurnProgressParams.Phase) async -> Void)?

    init(results: [TurnAwaitResult], awaitError: Error? = nil) {
        self.results = results
        self.awaitError = awaitError
    }

    private(set) var lastDebateJoin: DebateJoin?

    func openSession(
        model: String?,
        debate: DebateJoin?,
        onEnded: @escaping @Sendable (EndReason) async -> Void,
        onProgress: @escaping @Sendable (TurnProgressParams.Phase) async -> Void
    ) async throws -> (sessionId: String, firstTurnId: String) {
        openSessionCallCount += 1
        lastDebateJoin = debate
        self.onEnded = onEnded
        self.onProgress = onProgress
        return ("session-\(openSessionCallCount)", "t1")
    }

    struct OutOfResults: Error {}

    func awaitTurn(sessionId: String, turnId: String,
                  assistant: AssistantMessage?, waitMs: Int,
                  model: String?) async throws -> TurnAwaitResult {
        awaitCalls.append((sessionId, turnId, assistant))
        if let awaitError { throw awaitError }
        guard !results.isEmpty else { throw OutOfResults() }
        return results.removeFirst()
    }

    func closeSession(sessionId: String, reason: EndReason) async {
        closeCalls.append((sessionId, reason))
    }

    func discardSession() async {
        discardCallCount += 1
    }

    /// Simulates an out-of-band push — a `session.ended`/`turn.progress`
    /// notification arriving with nothing currently blocked in `awaitTurn`.
    /// Directly `await`ing the stored closure (rather than the engine
    /// spawning an untracked `Task` to call it) is exactly what makes this
    /// deterministically testable.
    func pushEnded(_ reason: EndReason) async { await onEnded?(reason) }
    func pushProgress(_ phase: TurnProgressParams.Phase) async { await onProgress?(phase) }
}

@Suite("Converse session engine — §4, R-MCP-17")
struct ConverseSessionEngineTests {

    @Test("R-MCP-7 — message and continuation together is rejected before touching the gateway")
    func bothArgumentsRejected() async throws {
        let gateway = MockGateway(results: [])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        await #expect(throws: ConverseEngineError.self) {
            _ = try await engine.converse(message: "hi", continuation: "tok")
        }
        let calls = await gateway.openSessionCallCount
        #expect(calls == 0)
    }

    @Test("a bare first call opens a session and awaits with no assistant message")
    func firstCallOpensSession() async throws {
        let gateway = MockGateway(results: [.prompt(turnId: "t1", nextTurnId: "t2", markdown: "hello")])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        let result = try await engine.converse(message: nil, continuation: nil)
        #expect(result.status == .prompt)
        #expect(result.userMessage == "hello")
        #expect(result.turn == 1)
        #expect(result.note == nil)

        let calls = await gateway.awaitCalls
        #expect(calls.count == 1)
        #expect(calls[0].assistant == nil)
        let opens = await gateway.openSessionCallCount
        #expect(opens == 1)
    }

    @Test("R-MCP-8 — a message on the skipped-open call is dropped with a note, not sent")
    func messageOnFirstCallIsDropped() async throws {
        let gateway = MockGateway(results: [.prompt(turnId: "t1", nextTurnId: "t2", markdown: "hello")])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        let result = try await engine.converse(message: "premature reply", continuation: nil)
        #expect(result.note != nil)
        #expect(result.note?.contains("first call") == true)

        let calls = await gateway.awaitCalls
        #expect(calls[0].assistant == nil, "the premature message must never reach awaitTurn")
    }

    @Test("a forged or mismatched continuation is refused")
    func badContinuationRejected() async throws {
        let gateway = MockGateway(results: [.pending(turnId: "t1")])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        _ = try await engine.converse(message: nil, continuation: nil)   // opens session, gets .pending

        await #expect(throws: ConverseEngineError.self) {
            _ = try await engine.converse(message: nil, continuation: "not-a-real-token")
        }
    }

    @Test(".pending round-trips to .waiting and the resulting token resumes correctly")
    func pendingRoundTrips() async throws {
        let gateway = MockGateway(results: [
            .pending(turnId: "t1"),
            .prompt(turnId: "t1", nextTurnId: "t2", markdown: "finally"),
        ])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        let first = try await engine.converse(message: nil, continuation: nil)
        #expect(first.status == .waiting)
        let token = try #require(first.continuation)

        let second = try await engine.converse(message: nil, continuation: token)
        #expect(second.status == .prompt)
        #expect(second.userMessage == "finally")
    }

    @Test("R-MCP-17 — a bare call after ended starts a genuinely new conversation")
    func restartsAfterEnded() async throws {
        let gateway = MockGateway(results: [
            .ended(.userEnded),
            .prompt(turnId: "t1", nextTurnId: "t2", markdown: "second conversation"),
        ])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        let ended = try await engine.converse(message: nil, continuation: nil)
        #expect(ended.status == .ended)

        // This is the exact bug fixed earlier: without the restart, this call
        // would just return `.ended` again forever.
        let restarted = try await engine.converse(message: nil, continuation: nil)
        #expect(restarted.status == .prompt)
        #expect(restarted.userMessage == "second conversation")

        let opens = await gateway.openSessionCallCount
        #expect(opens == 2, "the second conversation must open a genuinely new session")
        let discards = await gateway.discardCallCount
        #expect(discards == 1)
    }

    @Test("a call still carrying message or continuation after ended repeats the stale result")
    func staleArgumentsAfterEndedDoNotRestart() async throws {
        let gateway = MockGateway(results: [.ended(.windowClosed)])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        _ = try await engine.converse(message: nil, continuation: nil)

        let result = try await engine.converse(message: "the model missed the memo", continuation: nil)
        #expect(result.status == .ended)
        #expect(result.reason == EndReason.windowClosed.rawValue)

        let opens = await gateway.openSessionCallCount
        #expect(opens == 1, "a call carrying arguments after ended must not reopen a session")
    }

    @Test("an out-of-band ended push means the very next bare call restarts immediately")
    func pushedEndedShortCircuitsImmediately() async throws {
        // Without the push, this exact sequence (window closes with nothing
        // in flight, then a bare call arrives) would have no way to learn the
        // old session died until it tried — and failed — against it. The
        // push means `endedReason` is already set, so the bare call goes
        // straight to `startFresh()` and opens turn two immediately.
        let gateway = MockGateway(results: [
            .prompt(turnId: "t1", nextTurnId: "t2", markdown: "hi"),
            .prompt(turnId: "t1", nextTurnId: "t2", markdown: "fresh conversation"),
        ])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        _ = try await engine.converse(message: nil, continuation: nil)   // opens the session
        await gateway.pushEnded(.peerLost)                               // window closes with nothing in flight

        let result = try await engine.converse(message: nil, continuation: nil)
        #expect(result.status == .prompt)
        #expect(result.userMessage == "fresh conversation")

        let opens = await gateway.openSessionCallCount
        #expect(opens == 2, "the push must be reflected immediately, restarting on the very next bare call")
        let calls = await gateway.awaitCalls
        #expect(calls.count == 2, "no failed round-trip against the dead session in between")
    }

    @Test("an out-of-band progress push updates currentPhaseMessage")
    func pushedProgressUpdatesPhase() async throws {
        let gateway = MockGateway(results: [.prompt(turnId: "t1", nextTurnId: "t2", markdown: "hi")])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        _ = try await engine.converse(message: nil, continuation: nil)
        let before = await engine.currentPhaseMessage

        await gateway.pushProgress(.speaking)
        let after = await engine.currentPhaseMessage

        #expect(before != after)
    }

    @Test("shutdown is a no-op when no session was ever opened")
    func shutdownNoopWhenNeverOpened() async throws {
        let gateway = MockGateway(results: [])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        await engine.shutdown(reason: .mcpExit)

        let closes = await gateway.closeCalls
        #expect(closes.isEmpty)
    }

    @Test("shutdown closes exactly the open session, once")
    func shutdownClosesOpenSession() async throws {
        let gateway = MockGateway(results: [.prompt(turnId: "t1", nextTurnId: "t2", markdown: "hi")])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        _ = try await engine.converse(message: nil, continuation: nil)
        await engine.shutdown(reason: .mcpExit)

        let closes = await gateway.closeCalls
        #expect(closes.count == 1)
        #expect(closes[0].reason == .mcpExit)
    }

    @Test("an arbitrary gateway error propagates through converse unwrapped")
    func gatewayErrorsPropagateUnwrapped() async throws {
        let gateway = MockGateway(results: [], awaitError: DummyError())
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 1000)

        await #expect(throws: DummyError.self) {
            _ = try await engine.converse(message: nil, continuation: nil)
        }
    }
}

@Suite("Joining a debate — the seat travels with the first call only")
struct ConverseDebateJoinTests {

    @Test("the seat is passed when the window is opened")
    func passesTheSeatOnOpen() async throws {
        let gateway = MockGateway(results: [.prompt(turnId: "t1", nextTurnId: "t2", markdown: "hello")])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 10)

        _ = try await engine.converse(message: nil, continuation: nil, model: "claude-opus-5",
                                      debate: DebateJoin(roomID: "owl-42", seat: "for"))
        #expect(await gateway.lastDebateJoin == DebateJoin(roomID: "owl-42", seat: "for"))
    }

    @Test("a debate is just a conversation after the first call")
    func laterCallsAreOrdinary() async throws {
        let gateway = MockGateway(results: [
            .prompt(turnId: "t1", nextTurnId: "t2", markdown: "their opening"),
            .prompt(turnId: "t2", nextTurnId: "t3", markdown: "their answer"),
        ])
        let engine = ConverseSessionEngine(gateway: gateway, waitMs: 10)

        _ = try await engine.converse(message: nil, continuation: nil,
                                      debate: DebateJoin(roomID: "owl-42", seat: "for"))
        let second = try await engine.converse(message: "my reply", continuation: nil)

        #expect(second.status == .prompt)
        #expect(await gateway.openSessionCallCount == 1, "one window, one seat")
    }
}
