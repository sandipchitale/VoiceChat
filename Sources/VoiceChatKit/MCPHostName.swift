import Foundation

/// The name shown for the MCP host (Claude Code, Claude Desktop, …) that is
/// driving a conversation. It comes from the host's own `initialize` request,
/// not from the model, so it can't be wrong or missing because the model
/// forgot to pass it.
public enum MCPHostName {
    /// Hosts that send only a machine name, mapped to how people refer to them.
    static let known: [String: String] = [
        "claude-code": "Claude Code",
        "claude-ai": "Claude Desktop",
    ]

    /// The host's own `title` if it sends one, else a friendly name for a
    /// known host, else the raw `name` exactly as the host sent it.
    public static func display(name: String, title: String?) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return known[name.lowercased()] ?? name
    }
}
