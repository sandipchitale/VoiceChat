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
    /// The MCP host, as it named itself in `initialize`. Set before any
    /// `converse` call can arrive, since `initialize` always comes first.
    private var host: HelloParams.Peer?
    /// Asks the MCP client for its roots. Set only when the client said in
    /// `initialize` that it supports them.
    private var rootsProvider: (@Sendable () async -> [WorkspaceRoot])?
    private var sessionId: String?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func setHost(_ host: HelloParams.Peer) { self.host = host }

    func setRootsProvider(_ provider: @escaping @Sendable () async -> [WorkspaceRoot]) {
        self.rootsProvider = provider
    }

    /// Fetches the host's roots and hands them to the window. Runs detached
    /// from the conversation: roots are decoration, so a host that is slow to
    /// answer — or answers not at all — must not delay a turn.
    func refreshRoots() {
        guard let rootsProvider else { return }
        Task { [weak self] in
            let roots = await rootsProvider()
            await self?.sendRoots(roots)
        }
    }

    private func sendRoots(_ roots: [WorkspaceRoot]) async {
        guard let client, let sessionId, !roots.isEmpty else { return }
        _ = try? await client.callRaw(.sessionRoots,
                                      SessionRootsParams(sessionId: sessionId, roots: roots))
    }

    func openSession(
        model: String?,
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
            host: host)
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
                                  host: host?.name,
                                  cwd: FileManager.default.currentDirectoryPath,
                                  model: model),
                as: SessionOpenResult.self)
        } catch let e as VCPError { throw ConverseTransportError.vcp(e) }
        catch { throw ConverseTransportError.transport("\(error)") }

        Task { [weak self] in await self?.consumeNotifications(client, onEnded: onEnded, onProgress: onProgress) }

        sessionId = opened.sessionId
        refreshRoots()

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
                   assistant: AssistantMessage?, waitMs: Int,
                   model: String?) async throws -> TurnAwaitResult {
        guard let client else { throw ConverseTransportError.transport("no session") }
        let params = TurnAwaitParams(sessionId: sessionId, turnId: turnId, assistant: assistant, waitMs: waitMs,
                                     model: model)
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
        self.sessionId = nil
    }

    /// R-MCP-17 — the conversation already ended; there is nothing left to
    /// notify, just drop the stale connection.
    func discardSession() async {
        await client?.close()
        client = nil
        sessionId = nil
    }
}

