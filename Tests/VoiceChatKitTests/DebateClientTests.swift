import Foundation
import Testing
@testable import VoiceChatKit

@Suite("Debate clients — the commands that join a seat unattended (R-DEB-11)")
struct DebateClientTests {
    private let server = "/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp"
    private let instruction = #"Join the VoiceChat debate "owl-42" as the "for" side"#

    @Test func claudeGetsVoiceChatsServerAndOnlyConverse() throws {
        let arguments = DebateClient.claude.arguments(instruction: instruction, mcpServer: server)
        #expect(arguments.first == "-p")
        #expect(arguments[1] == instruction)
        #expect(arguments.contains("--strict-mcp-config"))
        let allowed = try #require(arguments.firstIndex(of: "--allowedTools"))
        #expect(arguments[allowed + 1] == "mcp__voicechat__converse")

        let configIndex = try #require(arguments.firstIndex(of: "--mcp-config"))
        let config = try JSONSerialization.jsonObject(with: Data(arguments[configIndex + 1].utf8)) as? [String: Any]
        let voicechat = (config?["mcpServers"] as? [String: Any])?["voicechat"] as? [String: Any]
        #expect(voicechat?["type"] as? String == "stdio")
        #expect(voicechat?["command"] as? String == server)
        #expect((voicechat?["env"] as? [String: String])?["VOICECHAT_TURN_WAIT_MS"] == "60000")
    }

    @Test func codexGetsVoiceChatsServerAsConfigOverrides() {
        let arguments = DebateClient.codex.arguments(instruction: instruction, mcpServer: server)
        #expect(Array(arguments.prefix(4)) == ["exec", "--skip-git-repo-check", "-s", "read-only"])
        #expect(arguments.contains("mcp_servers.voicechat.command=\"\(server)\""))
        #expect(arguments.contains("mcp_servers.voicechat.env={VOICECHAT_TURN_WAIT_MS=\"45000\"}"))
        #expect(arguments.contains("mcp_servers.voicechat.tool_timeout_sec=300"))
        #expect(arguments.last == instruction)
    }

    @Test func antigravityUsesItsOwnConfigAndSkipsPrompts() {
        #expect(DebateClient.antigravity.arguments(instruction: instruction, mcpServer: server)
                == ["-p", instruction, "--dangerously-skip-permissions"])
    }

    @Test func tomlStringsAreEscaped() {
        #expect(DebateClient.tomlString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }

    @Test func theFirstExecutableOnThePathWins() {
        let executables: Set<String> = ["/b/claude", "/c/claude", "/c/codex"]
        let isExecutable = { executables.contains($0) }
        #expect(DebateClient.find("claude", onPath: "/a::/b:/c", isExecutable: isExecutable) == "/b/claude")
        #expect(DebateClient.find("codex", onPath: "/a:/b:/c", isExecutable: isExecutable) == "/c/codex")
        #expect(DebateClient.find("agy", onPath: "/a:/b:/c", isExecutable: isExecutable) == nil)
    }

    @Test func eachClientIsLookedForByItsCommand() {
        #expect(DebateClient.allCases.map(\.executableName) == ["claude", "agy", "codex"])
    }
}

@Suite("Debate clients — the editable command lines")
struct DebateClientCommandLineTests {
    private let server = "/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp"

    @Test func theInstructionComesFromTheEnvironment() {
        #expect(DebateClient.antigravity.commandLine(mcpServer: server)
                == #"agy -p "$VOICECHAT_JOIN" --dangerously-skip-permissions"#)
        #expect(DebateClient.claude.commandLine(mcpServer: server).hasPrefix(#"claude -p "$VOICECHAT_JOIN" --mcp-config '{"#))
        #expect(DebateClient.codex.commandLine(mcpServer: server).hasSuffix(#" "$VOICECHAT_JOIN""#))
    }

    @Test func wordsAreQuotedForTheShell() {
        #expect(DebateClient.shellQuoted("read-only") == "read-only")
        #expect(DebateClient.shellQuoted("a b") == "'a b'")
        #expect(DebateClient.shellQuoted("it's") == #"'it'\''s'"#)
        #expect(DebateClient.shellQuoted(#"mcp_servers.voicechat.command="/x y""#) == #"'mcp_servers.voicechat.command="/x y"'"#)
    }

    /// The proposed command, run by a real shell, passes each argument through intact.
    @Test func theShellSeesTheSameArguments() throws {
        for client in DebateClient.allCases {
            let command = client.commandLine(mcpServer: server)
                .replacingOccurrences(of: client.executableName + " ", with: "printf '%s\\n' ", options: .anchored)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["VOICECHAT_JOIN": "Join \"owl-42\" now"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            #expect(lines == client.arguments(instruction: "Join \"owl-42\" now", mcpServer: server))
        }
    }
}
