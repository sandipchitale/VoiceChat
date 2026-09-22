import Foundation
import MCP

// MCP roots — the folders the host has told this server it is working in.
//
// Roots are the host's own answer to "what is this conversation about?", so
// they are worth showing to the person: the stdio server can only report its
// own working directory, and the HTTP server has no directory at all.

public struct WorkspaceRoot: Sendable, Codable, Equatable, Identifiable {
    /// The root's URI, as the host gave it. Normally `file://…`.
    public var uri: String
    /// The host's own label for it, if it supplied one.
    public var name: String?

    public var id: String { uri }

    public init(uri: String, name: String? = nil) {
        self.uri = uri
        self.name = name
    }

    /// The local path, for a `file://` root; `nil` for anything else.
    public var path: String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    /// Tilde-abbreviated path, else the raw URI — what the window shows.
    public var displayPath: String {
        path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? uri
    }

    /// The host's label, else the folder name, else the raw URI.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let path, !path.isEmpty {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty, last != "/" { return last }
        }
        return uri
    }

    public init(_ root: Root) {
        self.init(uri: root.uri, name: root.name)
    }
}

/// Asks the connected MCP client for its roots, giving up quietly rather than
/// waiting forever: roots are decoration, and a client that never answers must
/// not hold up the conversation.
public enum WorkspaceRoots {
    public static func fetch(from server: Server,
                             timeout: Duration = .seconds(5)) async -> [WorkspaceRoot] {
        let request = Task { try await server.listRoots() }
        let limit = Task {
            try? await Task.sleep(for: timeout)
            request.cancel()
        }
        defer { limit.cancel() }
        guard let roots = try? await request.value else { return [] }
        return roots.map(WorkspaceRoot.init)
    }
}
