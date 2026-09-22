import Foundation
import VoiceChatKit

// Spec R-TST-1 — drives a full conversation over VCP with no MCP host, so the
// window and speech paths can be exercised in isolation.
//
//   vcp-probe                       one turn, then end
//   vcp-probe --turns 3             three turns
//   vcp-probe --wait-ms 2000        short bounded waits, to exercise `pending`
//   vcp-probe --model claude-sonnet-5          model shown in the badge in the window

struct Options {
    var turns = 1
    var waitMs = 240_000
    var socket = VCP.defaultSocketURL().path
    var model: String?
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--turns":   o.turns = Int(it.next() ?? "") ?? o.turns
        case "--wait-ms": o.waitMs = Int(it.next() ?? "") ?? o.waitMs
        case "--socket":  o.socket = it.next() ?? o.socket
        case "--model":   o.model = it.next()
        default:
            FileHandle.standardError.write(Data("unknown option: \(arg)\n".utf8))
            exit(2)
        }
    }
    return o
}

func say(_ s: String) { print(s); fflush(stdout) }

let options = parseOptions()

let channel: VCPChannel
do {
    channel = try DaemonLauncher.connect(socketPath: options.socket)
} catch let e as DaemonLaunchError {
    say("could not reach the daemon: \(e.actionableSentence)")
    exit(1)
} catch {
    say("could not reach the daemon: \(error)")
    exit(1)
}

let client = VCPClient(channel: channel)

let hello = try await client.call(
    .hello,
    HelloParams(client: .init(name: "vcp-probe", version: VoiceChatVersion.string,
                              pid: ProcessInfo.processInfo.processIdentifier)),
    as: HelloResult.self)
say("connected to daemon \(hello.daemonVersion), vcp v\(hello.vcpVersion)")

let sessionId = UUID().uuidString
let opened = try await client.call(
    .sessionOpen,
    SessionOpenParams(sessionId: sessionId, title: "vcp-probe", host: "vcp-probe",
                      model: options.model),
    as: SessionOpenResult.self)
say("session \(opened.sessionId) open, first turn \(opened.turnId)")

var turnId = opened.turnId
var assistant: AssistantMessage?

loop: for n in 1...options.turns {
    while true {
        let result = try await client.call(
            .turnAwait,
            TurnAwaitParams(sessionId: sessionId, turnId: turnId,
                            assistant: assistant, waitMs: options.waitMs,
                            model: options.model),
            as: TurnAwaitResult.self)
        assistant = nil

        switch result.outcome {
        case .pending:
            say("turn \(n): still composing, resuming the wait")
            continue
        case .ended:
            say("session ended: \(result.reason?.rawValue ?? "unknown")")
            break loop
        case .prompt:
            say("turn \(n) prompt: \(result.markdown ?? "")")
            turnId = result.nextTurnId ?? turnId
            assistant = AssistantMessage(markdown: """
                You said: **\(result.markdown ?? "")**

                This is `vcp-probe` echoing you back, so nothing here came from a model.
                """)
            continue loop
        }
    }
}

_ = try? await client.callRaw(.sessionClose,
                              SessionCloseParams(sessionId: sessionId, reason: .mcpExit))
await client.close()
say("done")
