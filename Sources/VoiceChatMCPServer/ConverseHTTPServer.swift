import Foundation
import MCP
import VoiceChatKit
import VoiceChatUI

// Wires the `converse` tool onto the SDK's Streamable HTTP transport,
// in-process, one `Server` + `ConverseSessionEngine` per `Mcp-Session-Id` —
// the direct HTTP analogue of what `voicechat-mcp` does per stdio process.

public actor ConverseHTTPServer {
    private let app: HTTPApp

    /// - Parameters:
    ///   - host: always pass `"127.0.0.1"` — the daemon never binds a
    ///     Streamable HTTP listener to anything but loopback.
    public init(host: String, port: Int, daemonServer: DaemonServer, waitMs: Int) {
        let configuration = HTTPApp.Configuration(host: host, port: port, endpoint: "/mcp")

        self.app = HTTPApp(configuration: configuration) { _, _ in
            let gateway = await InProcessSessionGateway(server: daemonServer)
            let engine = ConverseSessionEngine(gateway: gateway, waitMs: waitMs)

            let server = Server(
                name: "voicechat",
                version: VoiceChatVersion.string,
                capabilities: .init(tools: .init(listChanged: false))
            )

            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: [ConverseTool.tool()])
            }

            await server.withMethodHandler(CallTool.self) { params in
                guard params.name == ConverseTool.name else {
                    return CallTool.Result(content: [.text(text: "Unknown tool: \(params.name)")], isError: true)
                }

                let message: String? = if case .string(let s)? = params.arguments?["message"] { s } else { nil }
                let continuation: String? = if case .string(let s)? = params.arguments?["continuation"] { s } else { nil }
                let model: String? = if case .string(let s)? = params.arguments?["model"] { s } else { nil }

                let ticker = ConverseTool.startProgressTicker(
                    server: server,
                    progressToken: params._meta?.progressToken,
                    phaseMessage: { await engine.currentPhaseMessage }
                )
                defer { ticker.cancel() }

                do {
                    let result = try await engine.converse(message: message, continuation: continuation,
                                                           model: model)
                    return try CallTool.Result(
                        content: [.text(text: result.text)],
                        structuredContent: ConverseTool.structuredContent(result),
                        isError: false
                    )
                } catch let error as ConverseEngineError {
                    return CallTool.Result(content: [.text(text: error.actionableSentence)], isError: true)
                } catch let error as VCPError {
                    return CallTool.Result(content: [.text(text: error.actionableSentence)], isError: true)
                } catch {
                    return CallTool.Result(
                        content: [.text(text: "VoiceChat failed unexpectedly: \(error). Tell the user and stop.")],
                        isError: true)
                }
            }

            // Closing the HTTP session (explicit DELETE, idle timeout, or the
            // whole daemon quitting) must close this conversation's window —
            // the SDK's own reference adapter has no analogue for this, since
            // it isn't hosting anything with a visible lifetime of its own.
            let onClose: @Sendable () async -> Void = {
                await engine.shutdown(reason: .mcpExit)
            }
            // Each HTTP session is its own MCP connection, so it names its
            // own host in its own `initialize`.
            let initializeHook: HTTPApp.InitializeHook = { client, capabilities in
                await gateway.setHost(MCPHostName.display(name: client.name, title: client.title))
                if capabilities.roots != nil {
                    await gateway.setRootsProvider { await WorkspaceRoots.fetch(from: server) }
                }
            }

            await server.onNotification(RootsListChangedNotification.self) { _ in
                await gateway.refreshRoots()
            }
            return (server, onClose, initializeHook)
        }
    }

    /// Blocks until ``stop()`` is called — run this in its own `Task`.
    public func start() async throws {
        try await app.start()
    }

    public func stop() async {
        await app.stop()
    }
}
