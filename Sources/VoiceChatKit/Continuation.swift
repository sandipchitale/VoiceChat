import Foundation
import CryptoKit

// Spec R-MCP-6 — `continuation` is an opaque, authenticated encoding of
// (sessionId, turnId, nonce). The server rejects a token that does not match
// its own current state rather than trusting what came back from the model.

public struct ContinuationToken: Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let nonce: String

    public init(sessionId: String, turnId: String, nonce: String = UUID().uuidString) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.nonce = nonce
    }
}

public struct ContinuationSigner: Sendable {
    private let key: SymmetricKey

    /// A fresh key per process. Tokens are meaningless to any other process
    /// and do not survive a restart, which is exactly the intended lifetime
    /// (R-SEC-4).
    public init() {
        self.key = SymmetricKey(size: .bits256)
    }

    public init(keyData: Data) {
        self.key = SymmetricKey(data: keyData)
    }

    public func sign(_ token: ContinuationToken) -> String {
        let payload = "\(token.sessionId)|\(token.turnId)|\(token.nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let sig = Data(mac).base64EncodedString()
        return Data("\(payload)|\(sig)".utf8).base64EncodedString()
    }

    /// Returns the token only if the signature verifies *and* it matches the
    /// state the caller believes it is in.
    public func verify(_ encoded: String, expecting expected: ContinuationToken?) -> ContinuationToken? {
        guard let data = Data(base64Encoded: encoded),
              let joined = String(data: data, encoding: .utf8) else { return nil }
        let parts = joined.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }

        let payload = parts[0...2].joined(separator: "|")
        guard let sig = Data(base64Encoded: parts[3]) else { return nil }
        let expectedMac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        guard Data(expectedMac) == sig else { return nil }

        let token = ContinuationToken(sessionId: parts[0], turnId: parts[1], nonce: parts[2])
        if let expected {
            guard token.sessionId == expected.sessionId, token.turnId == expected.turnId else {
                return nil
            }
        }
        return token
    }
}

/// Turn identifiers. Monotonic within a session; the synchronisation token of
/// R-VCP-7.
public struct TurnSequence: Sendable, Equatable {
    private var n: Int
    public init(startingAt n: Int = 1) { self.n = n }

    public var current: String { "t\(n)" }

    public mutating func advance() -> String {
        n += 1
        return current
    }

    /// The turn a freshly opened session starts on.
    public static let first = TurnSequence().current

    public static func index(of turnId: String) -> Int? {
        guard turnId.hasPrefix("t") else { return nil }
        return Int(turnId.dropFirst())
    }
}
