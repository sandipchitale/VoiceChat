import Foundation

// Spec R-STT-22 — at most one session holds the microphone at a time.
//
// Two windows both listening would transcribe the same speech into both, and
// on most Macs the second engine simply fails to start. Arbitration makes the
// contention visible and recoverable instead.
//
// Ownership is a first-class lease keyed by session id. `acquire` hands back a
// `MicrophoneLease` token; `release` only takes effect if that token still
// matches the current owner, so a session that was already revoked cannot
// silently steal the microphone back from whoever displaced it.

/// A scoped claim on the microphone. Hold it while listening; hand it back to
/// `MicrophoneArbiter.release(_:)` when done. The `epoch` distinguishes
/// successive acquisitions so a stale lease is inert.
public struct MicrophoneLease: Sendable, Equatable {
    public let sessionID: String
    let epoch: UInt64
}

@MainActor
public final class MicrophoneArbiter {
    public static let shared = MicrophoneArbiter()

    private var ownerID: String?
    private var epoch: UInt64 = 0
    private var revoke: (() -> Void)?

    init() {}

    /// The session id currently holding the microphone, or `nil`.
    public var currentOwner: String? { ownerID }

    public func isHeld(by sessionID: String) -> Bool { ownerID == sessionID }

    /// Takes the microphone for `sessionID`, stopping whoever had it. `onRevoke`
    /// fires if someone else later claims it. Re-acquiring by the same session
    /// does not fire its own revoke. Returns the lease to release later.
    public func acquire(_ sessionID: String, onRevoke: @escaping () -> Void) -> MicrophoneLease {
        if let ownerID, ownerID != sessionID {
            revoke?()
        }
        ownerID = sessionID
        revoke = onRevoke
        epoch &+= 1
        return MicrophoneLease(sessionID: sessionID, epoch: epoch)
    }

    /// No-op unless `lease` matches the current owner and epoch, so a displaced
    /// owner's stale release cannot clear a newer owner's microphone.
    public func release(_ lease: MicrophoneLease) {
        guard ownerID == lease.sessionID, epoch == lease.epoch else { return }
        ownerID = nil
        revoke = nil
    }
}
