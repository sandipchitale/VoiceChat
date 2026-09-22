import Foundation
import VoiceChatKit
import VoiceChatUI

// Reaches a VoiceChat session directly, in the same process — no VCP hop, no
// socket, no JSON-RPC. This is what lets the daemon serve `converse` over
// Streamable HTTP with no protocol translation beyond MCP's own framing.

/// `@MainActor`-isolated since `DaemonServer`/`Session` are; `@unchecked
/// Sendable` is safe here because every stored property is touched
/// exclusively under that isolation — the same pattern `VCPListener` already
/// uses elsewhere in this codebase.
@MainActor
public final class InProcessSessionGateway: ConverseSessionGateway, @unchecked Sendable {
    private let server: DaemonServer
    private var host: String?
    private let cwd: String?
    private var session: Session?

    public init(server: DaemonServer, host: String? = nil, cwd: String? = nil) {
        self.server = server
        self.host = host
        self.cwd = cwd
    }

    /// The MCP host, as it named itself in `initialize` for this HTTP session.
    public func setHost(_ host: String) { self.host = host }

    public func openSession(
        model: String?,
        onEnded: @escaping @Sendable (EndReason) async -> Void,
        onProgress: @escaping @Sendable (TurnProgressParams.Phase) async -> Void
    ) async throws -> (sessionId: String, firstTurnId: String) {
        let id = UUID().uuidString
        let session = server.openSession(id: id, title: nil, host: host, cwd: cwd, model: model)
        // `Session.onEnded`/`.onProgress` are plain synchronous callbacks (the
        // same ones VCP's `PeerConnection` uses), so crossing into the async
        // gateway contract needs a `Task` here — exactly at the edge where a
        // synchronous AppKit-style callback meets async code, not buried
        // inside the shared engine.
        session.onEnded = { _, reason in Task { await onEnded(reason) } }
        session.onProgress = { _, phase in Task { await onProgress(phase) } }
        self.session = session
        return (id, session.firstTurnId)
    }

    /// Holding the `Session` directly, rather than re-looking it up by id on
    /// every call the way VCP's `PeerConnection` must, means this path can
    /// never hit an `unknownSession` race against disposal — the only way to
    /// reach this method without a `session` is a gateway that was never
    /// opened at all.
    public func awaitTurn(sessionId: String, turnId: String,
                          assistant: AssistantMessage?, waitMs: Int,
                          model: String?) async throws -> TurnAwaitResult {
        guard let session else { throw VCPError.unknownSession }
        let params = TurnAwaitParams(sessionId: sessionId, turnId: turnId, assistant: assistant, waitMs: waitMs,
                                     model: model)
        session.updateIdentity(model: model)
        return try await session.coordinator.awaitTurn(params) { markdown in
            Task { @MainActor in session.present(response: markdown) }
        }
    }

    public func closeSession(sessionId: String, reason: EndReason) async {
        server.closeSession(sessionId, reason: reason)
    }

    public func discardSession() async {
        session = nil
    }
}
