import Foundation
import VoiceChatKit

// Spec §4 — the VCP-specific half of the `converse` tool's session gateway.
// The transport-agnostic state machine lives in `VoiceChatKit`'s
// `ConverseSessionEngine`; this file only knows how to reach a session over
// VCP.

enum ConverseTransportError: Error {
    case vcp(VCPError)
    case launch(DaemonLaunchError)
    case transport(String)

    var actionableSentence: String {
        switch self {
        case .vcp(let e):    return e.actionableSentence
        case .launch(let e): return e.actionableSentence
        case .transport(let s):
            return "VoiceChat became unreachable (\(s)). Tell the user to relaunch VoiceChat, then stop."
        }
    }
}

/// An `actor` because it carries a live `VCPClient` across the
/// `openSession` → `awaitTurn` → `closeSession`/`discardSession` calls the
/// engine makes against it over the lifetime of one (or, after a restart,
/// several sequential) conversations.
actor VCPSessionGateway: ConverseSessionGateway {
    private let socketPath: String

    private var client: VCPClient?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func openSession(
        onEnded: @escaping @Sendable (EndReason) async -> Void,
        onProgress: @escaping @Sendable (TurnProgressParams.Phase) async -> Void
    ) async throws -> (sessionId: String, firstTurnId: String) {
        let channel: VCPChannel
        do { channel = try DaemonLauncher.connect(socketPath: socketPath) }
        catch let e as DaemonLaunchError { throw ConverseTransportError.launch(e) }
        catch { throw ConverseTransportError.transport("\(error)") }

        let client = VCPClient(channel: channel)
        self.client = client

        let hello = HelloParams(
            client: .init(name: "voicechat-mcp", version: VoiceChatVersion.string,
                          pid: ProcessInfo.processInfo.processIdentifier),
            host: HostIdentity.current)
        do {
            _ = try await client.call(.hello, hello, as: HelloResult.self)
        } catch let e as VCPError { throw ConverseTransportError.vcp(e) }
        catch { throw ConverseTransportError.transport("\(error)") }

        let id = UUID().uuidString
        let opened: SessionOpenResult
        do {
            opened = try await client.call(
                .sessionOpen,
                SessionOpenParams(sessionId: id, title: nil,
                                  host: HostIdentity.current?.name,
                                  cwd: FileManager.default.currentDirectoryPath),
                as: SessionOpenResult.self)
        } catch let e as VCPError { throw ConverseTransportError.vcp(e) }
        catch { throw ConverseTransportError.transport("\(error)") }

        Task { [weak self] in await self?.consumeNotifications(client, onEnded: onEnded, onProgress: onProgress) }

        return (opened.sessionId, opened.turnId)
    }

    private func consumeNotifications(
        _ client: VCPClient,
        onEnded: @escaping @Sendable (EndReason) async -> Void,
        onProgress: @escaping @Sendable (TurnProgressParams.Phase) async -> Void
    ) async {
        for await frame in await client.notifications {
            guard case .notification(let method, let params) = frame else { continue }
            switch method {
            case .sessionEnded:
                if let p = try? VCPCodec.decodePayload(SessionEndedParams.self, from: params) {
                    await onEnded(p.reason)
                }
            case .turnProgress:
                if let p = try? VCPCodec.decodePayload(TurnProgressParams.self, from: params) {
                    await onProgress(p.phase)
                }
            default:
                break
            }
        }
    }

    func awaitTurn(sessionId: String, turnId: String,
                   assistant: AssistantMessage?, waitMs: Int) async throws -> TurnAwaitResult {
        guard let client else { throw ConverseTransportError.transport("no session") }
        let params = TurnAwaitParams(sessionId: sessionId, turnId: turnId, assistant: assistant, waitMs: waitMs)
        do {
            return try await client.call(.turnAwait, params, as: TurnAwaitResult.self)
        } catch let e as VCPError {
            throw ConverseTransportError.vcp(e)
        } catch {
            throw ConverseTransportError.transport("\(error)")
        }
    }

    func closeSession(sessionId: String, reason: EndReason) async {
        guard let client else { return }
        _ = try? await client.callRaw(.sessionClose, SessionCloseParams(sessionId: sessionId, reason: reason))
        await client.close()
        self.client = nil
    }

    /// R-MCP-17 — the conversation already ended; there is nothing left to
    /// notify, just drop the stale connection.
    func discardSession() async {
        await client?.close()
        client = nil
    }
}

enum HostIdentity {
    /// Filled in from MCP `initialize` once the SDK surfaces it; until then the
    /// daemon shows a generic title.
    nonisolated(unsafe) static var current: HelloParams.Peer?
}
