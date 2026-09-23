import Foundation
import MCP
import VoiceChatKit

// Spec §4 — stdio MCP server.
//
// R-MCP-3: nothing but JSON-RPC frames may reach stdout. All diagnostics go to
// stderr and the log file.

func log(_ message: String) {
    FileHandle.standardError.write(Data("[voicechat-mcp] \(message)\n".utf8))
}

let socketPath = VCP.defaultSocketURL().path
let waitMs = max(10_000, Int(ProcessInfo.processInfo.environment["VOICECHAT_TURN_WAIT_MS"] ?? "") ?? 240_000)

let gateway = VCPSessionGateway(socketPath: socketPath)
let engine = ConverseSessionEngine(gateway: gateway, waitMs: waitMs)

// MARK: - Server

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
    let debateID: String? = if case .string(let s)? = params.arguments?["debate_id"] { s } else { nil }
    let side: String? = if case .string(let s)? = params.arguments?["side"] { s } else { nil }
    let debate = debateID.map { DebateJoin(roomID: $0, seat: side ?? "") }

    let ticker = ConverseTool.startProgressTicker(
        server: server,
        progressToken: params._meta?.progressToken,
        phaseMessage: { await engine.currentPhaseMessage }
    )
    defer { ticker.cancel() }

    do {
        let result = try await engine.converse(message: message, continuation: continuation,
                                               model: model, debate: debate)
        log("converse -> \(result.status.rawValue)")
        return try CallTool.Result(
            content: [.text(text: result.text)],
            structuredContent: ConverseTool.structuredContent(result),
            isError: false
        )
    } catch let error as ConverseEngineError {
        log("converse failed: \(error)")
        return CallTool.Result(content: [.text(text: error.actionableSentence)], isError: true)
    } catch let error as ConverseTransportError {
        log("converse failed: \(error)")
        return CallTool.Result(content: [.text(text: error.actionableSentence)], isError: true)
    } catch {
        log("converse failed: \(error)")
        return CallTool.Result(
            content: [.text(text: "VoiceChat failed unexpectedly: \(error). Tell the user and stop.")],
            isError: true)
    }
}

// R-MCP-15 — stdin EOF, SIGTERM and SIGINT all close the session cleanly so the
// daemon does not leave an orphaned window.
func installSignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            Task {
                await engine.shutdown(reason: .mcpExit)
                exit(0)
            }
        }
        source.resume()
        signalSources.append(source)
    }
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
installSignalHandlers()

// The host's roots name the folders this conversation is about — better than
// this process's own working directory, and the only such signal a host that
// supports roots offers.
await server.onNotification(RootsListChangedNotification.self) { _ in
    await gateway.refreshRoots()
}

let transport = StdioTransport()
try await server.start(transport: transport, initializeHook: { client, capabilities in
    await gateway.setHost(.init(name: MCPHostName.display(name: client.name, title: client.title),
                                version: client.version))
    if capabilities.roots != nil {
        await gateway.setRootsProvider { await WorkspaceRoots.fetch(from: server) }
    }
})
await server.waitUntilCompleted()
await engine.shutdown(reason: .mcpExit)
