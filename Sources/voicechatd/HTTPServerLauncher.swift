import Foundation

// Spec §4 / §10 — configuration for the optional Streamable HTTP MCP
// transport. Startup/shutdown is owned by `AppDelegate` directly (it needs to
// toggle the server on and off from a menu item, not just once at launch),
// so this is just the shared, static configuration both paths read.

enum HTTPServerLauncher {
    /// Never binds anything but loopback. A TCP listener on 127.0.0.1 is
    /// reachable by any local user account, not just the one that launched
    /// VoiceChat — a real trust-boundary downgrade versus VCP's `0600` socket,
    /// accepted here as the inherent cost of a TCP-based transport at all,
    /// not something the on/off toggle tries to engineer around.
    static let host = "127.0.0.1"

    static let defaultPort = 8765

    /// `VOICECHAT_MCP_HTTP_PORT`, if set, both picks the port and means the
    /// server auto-starts at launch; if unset, the menu item still offers to
    /// start it on this default port, just not automatically.
    static var configuredPort: Int {
        ProcessInfo.processInfo.environment["VOICECHAT_MCP_HTTP_PORT"].flatMap(Int.init) ?? defaultPort
    }

    static var startsAutomatically: Bool {
        ProcessInfo.processInfo.environment["VOICECHAT_MCP_HTTP_PORT"] != nil
    }

    static var waitMs: Int {
        max(10_000, Int(ProcessInfo.processInfo.environment["VOICECHAT_TURN_WAIT_MS"] ?? "") ?? 240_000)
    }
}
