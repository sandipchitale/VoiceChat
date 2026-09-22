import Foundation
import Testing
@testable import VoiceChatKit

@Suite("Workspace roots — what the window shows for an MCP root")
struct WorkspaceRootTests {

    @Test("a file root reads as its folder name over a tilde-abbreviated path")
    func fileRoot() {
        let home = NSHomeDirectory()
        let root = WorkspaceRoot(uri: URL(fileURLWithPath: home + "/code/VoiceChat").absoluteString)
        #expect(root.path == home + "/code/VoiceChat")
        #expect(root.displayName == "VoiceChat")
        #expect(root.displayPath == "~/code/VoiceChat")
    }

    @Test("the host's own name wins over the folder name")
    func namedRoot() {
        let root = WorkspaceRoot(uri: "file:///tmp/work", name: "Work tree")
        #expect(root.displayName == "Work tree")
    }

    @Test("a non-file root falls back to its URI")
    func otherScheme() {
        let root = WorkspaceRoot(uri: "https://example.com/repo")
        #expect(root.path == nil)
        #expect(root.displayPath == "https://example.com/repo")
        #expect(root.displayName == "https://example.com/repo")
    }

    @Test("roots survive the VCP wire unchanged")
    func roundTrip() throws {
        let params = SessionRootsParams(sessionId: "s1", roots: [
            WorkspaceRoot(uri: "file:///tmp/a", name: "A"),
            WorkspaceRoot(uri: "file:///tmp/b"),
        ])
        let frame = try VCPCodec.notification(method: .sessionRoots, params: params)
        let line = String(decoding: frame, as: UTF8.self)
        #expect(line.contains("session.roots"))
        let decoded = try JSONDecoder().decode(Envelope.self, from: frame)
        #expect(decoded.params == params)
    }

    private struct Envelope: Decodable {
        let params: SessionRootsParams
    }
}
