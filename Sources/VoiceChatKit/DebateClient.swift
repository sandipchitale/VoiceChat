import Foundation

// Spec §17, R-DEB-11 — a command-line AI client the New Debate dialog can start
// to take a seat by itself, instead of the person pasting the join instruction
// into it. Only the commands are built here (headless, so they are tested
// without launching anything); `DebateClientLauncher` runs them.

public enum DebateClient: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case claude, antigravity, codex

    public var id: String { rawValue }

    /// The command looked for on the person's PATH.
    public var executableName: String {
        switch self {
        case .claude: "claude"
        case .antigravity: "agy"
        case .codex: "codex"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        case .codex: "Codex"
        }
    }

    /// How it is run, for the picker: "claude -p".
    public var commandHint: String {
        switch self {
        case .claude: "claude -p"
        case .antigravity: "agy -p"
        case .codex: "codex exec"
        }
    }

    /// Seconds a `converse` call may wait before returning `waiting`, kept under
    /// each host's own tool timeout (Codex's is raised to 300 s below).
    static let claudeWaitMs = "60000"
    static let codexWaitMs = "45000"

    /// The arguments that run this client unattended on `instruction` (a seat's
    /// join instruction).
    ///
    /// - Claude Code and Codex are given VoiceChat's stdio server
    ///   (`mcpServer`, the `voicechat-mcp` inside this app) on the command line,
    ///   so their own configuration doesn't matter, and Claude may call only
    ///   `converse`.
    /// - Antigravity can't be given a server that way: it uses its own MCP
    ///   configuration, and skips permission prompts, which nobody could answer
    ///   in print mode.
    public func arguments(instruction: String, mcpServer: String) -> [String] {
        switch self {
        case .claude:
            return ["-p", instruction,
                    "--mcp-config", Self.claudeMCPConfig(mcpServer: mcpServer),
                    "--strict-mcp-config",
                    "--allowedTools", "mcp__voicechat__converse"]
        case .codex:
            return ["exec", "--skip-git-repo-check", "-s", "read-only",
                    "-c", "mcp_servers.voicechat.command=\(Self.tomlString(mcpServer))",
                    "-c", "mcp_servers.voicechat.env={VOICECHAT_TURN_WAIT_MS=\(Self.tomlString(Self.codexWaitMs))}",
                    "-c", "mcp_servers.voicechat.tool_timeout_sec=300",
                    instruction]
        case .antigravity:
            return ["-p", instruction, "--dangerously-skip-permissions"]
        }
    }

    /// The environment variable holding the seat's join instruction when a
    /// client's command runs, so an edited command keeps working when the
    /// motion changes.
    public static let instructionVariable = "VOICECHAT_JOIN"

    /// The proposed command line, for the person to review and edit in the New
    /// Debate dialog. It is run by the shell, with the join instruction in
    /// `$VOICECHAT_JOIN`.
    public func commandLine(mcpServer: String) -> String {
        let placeholder = "\u{0}instruction\u{0}"
        let words = [executableName] + arguments(instruction: placeholder, mcpServer: mcpServer)
        return words.map { $0 == placeholder ? "\"$\(Self.instructionVariable)\"" : Self.shellQuoted($0) }
            .joined(separator: " ")
    }

    /// `word` quoted for a POSIX shell: bare when it is plainly safe, else in
    /// single quotes.
    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `--mcp-config` for Claude Code: VoiceChat's stdio server, named
    /// `voicechat`, with a shorter wait per call.
    static func claudeMCPConfig(mcpServer: String) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                "voicechat": [
                    "type": "stdio",
                    "command": mcpServer,
                    "env": ["VOICECHAT_TURN_WAIT_MS": claudeWaitMs],
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A TOML basic string, for Codex's `-c key=value` overrides.
    static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The first executable called `name` on `path` (a colon-separated PATH).
    public static func find(_ name: String, onPath path: String,
                            isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
