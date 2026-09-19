import Foundation

// Spec R-ARCH-3 — the MCP server must be able to start the daemon.

public enum DaemonLauncher {
    public static let bundleIdentifier = "dev.sandipchitale.voicechat"

    public struct Resolution: Sendable {
        public var appURL: URL?
        public var triedPaths: [String]
    }

    /// Resolution order: `$VOICECHAT_APP_PATH`, then Launch Services, then the
    /// bundle containing this executable.
    public static func resolveApp() -> Resolution {
        var tried: [String] = []
        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment["VOICECHAT_APP_PATH"] {
            tried.append(override)
            if fm.fileExists(atPath: override) {
                return Resolution(appURL: URL(fileURLWithPath: override), triedPaths: tried)
            }
        }

        // …/VoiceChat.app/Contents/MacOS/voicechat-mcp → …/VoiceChat.app
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = exe.deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // *.app
        if sibling.pathExtension == "app" {
            tried.append(sibling.path)
            if fm.fileExists(atPath: sibling.path) {
                return Resolution(appURL: sibling, triedPaths: tried)
            }
        }

        let conventional = "/Applications/VoiceChat.app"
        tried.append(conventional)
        if fm.fileExists(atPath: conventional) {
            return Resolution(appURL: URL(fileURLWithPath: conventional), triedPaths: tried)
        }

        return Resolution(appURL: nil, triedPaths: tried)
    }

    /// Launches detached and without activating, so a conversation window does
    /// not steal focus from whatever the person is doing.
    @discardableResult
    public static func launch(_ appURL: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-j", appURL.path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Connect, starting the daemon first if it is not already listening.
    public static func connect(socketPath: String, launchTimeout: TimeInterval = 10) throws
        -> VCPChannel
    {
        do {
            return try VCPDialer.connect(path: socketPath)
        } catch {
            // A running daemon we simply cannot reach because this process is
            // sandboxed: launching the app again would not help. Report it.
            if isSandboxDenied(error) {
                throw DaemonLaunchError.sandboxDenied(
                    socketPath: socketPath, mcpBinaryPath: mcpBinaryPath())
            }
            // Otherwise the daemon is probably not running yet — fall through.
        }

        let resolution = resolveApp()
        guard let appURL = resolution.appURL else {
            throw DaemonLaunchError.applicationNotFound(tried: resolution.triedPaths)
        }
        guard launch(appURL) else {
            throw DaemonLaunchError.launchFailed(path: appURL.path)
        }
        do {
            return try VCPDialer.connect(path: socketPath, waitingUpTo: launchTimeout)
        } catch {
            if isSandboxDenied(error) {
                throw DaemonLaunchError.sandboxDenied(
                    socketPath: socketPath, mcpBinaryPath: mcpBinaryPath())
            }
            throw DaemonLaunchError.didNotListen(path: socketPath, seconds: launchTimeout)
        }
    }

    /// EPERM on `connect(2)` is how a sandbox (e.g. Company Claude Code) refuses a
    /// local socket, and it is indistinguishable from any other cause at the
    /// text level — so we key off the errno.
    private static func isSandboxDenied(_ error: Error) -> Bool {
        if case VCPSocketError.connectFailed(let e, _) = error, e == EPERM { return true }
        return false
    }

    /// The path this MCP executable was launched as — exactly the `command`
    /// registered in `.mcp.json`, and therefore the string to add to a
    /// sandbox's allowlist.
    private static func mcpBinaryPath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }
}

public enum DaemonLaunchError: Error, Equatable {
    case applicationNotFound(tried: [String])
    case launchFailed(path: String)
    case didNotListen(path: String, seconds: TimeInterval)
    case sandboxDenied(socketPath: String, mcpBinaryPath: String)

    /// R-ERR-3 — what the model is told: plain, and explicitly terminal.
    public var actionableSentence: String {
        switch self {
        case .applicationNotFound(let tried):
            return
                "VoiceChat could not be started. The application was not found at: \(tried.joined(separator: ", ")). Tell the user to install or launch VoiceChat, then stop."
        case .launchFailed(let path):
            return
                "VoiceChat was found at \(path) but could not be launched. Tell the user to open it manually, then stop."
        case .didNotListen(let path, let seconds):
            return
                "VoiceChat was launched but did not start listening at \(path) within \(Int(seconds)) seconds. Tell the user to check VoiceChat is running, then stop."
        case .sandboxDenied(_, let mcpBinaryPath):
            return
                "VoiceChat is running, but this MCP server is sandboxed and cannot reach VoiceChat's local socket (connect denied). Tell the user to add this exact executable to Claude Code's unsandbox allowlist: \(mcpBinaryPath) — then reconnect the voicechat MCP server. Then stop."
        }
    }
}
