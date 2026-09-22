import Testing
@testable import VoiceChatKit

@Suite("MCP host display name")
struct MCPHostNameTests {
    @Test("a host's own title wins over everything")
    func titleWins() {
        #expect(MCPHostName.display(name: "claude-code", title: "Claude Code (beta)") == "Claude Code (beta)")
    }

    @Test("known machine names get the name people use")
    func knownNames() {
        #expect(MCPHostName.display(name: "claude-code", title: nil) == "Claude Code")
        #expect(MCPHostName.display(name: "claude-ai", title: nil) == "Claude Desktop")
        #expect(MCPHostName.display(name: "Claude-Code", title: "  ") == "Claude Code")
    }

    @Test("an unknown host is shown exactly as it named itself")
    func unknownPassesThrough() {
        #expect(MCPHostName.display(name: "cursor-vscode", title: nil) == "cursor-vscode")
    }
}
