import AppKit
import Foundation
import VoiceChatKit

// Spec §3 — the daemon's side of VCP: accept peers, dispatch methods, own the
// session registry.

/// `@unchecked Sendable` because every stored property is exclusively
/// touched under `@MainActor` isolation — needed so `VoiceChatMCPServer`'s
/// HTTP session factory (a `@Sendable` closure, since it crosses into an
/// actor-isolated NIO event loop) can capture a `DaemonServer` reference.
@MainActor
public final class DaemonServer: @unchecked Sendable {
    private let listener: VCPListener
    private var peers: [ObjectIdentifier: PeerConnection] = [:]
    public private(set) var sessions: [String: Session] = [:]

    public let daemonVersion: String
    public var onSessionsChanged: (() -> Void)?

    public init(socketPath: String = VCP.defaultSocketURL().path, version: String) {
        self.listener = VCPListener(path: socketPath)
        self.daemonVersion = version
    }

    public func start() throws {
        listener.onPeer = { [weak self] channel in
            Task { @MainActor in self?.accept(channel) }
        }
        try listener.start()
    }

    public func stop() {
        // R-VCP-14 — resolve every in-flight wait before the socket closes.
        for session in sessions.values {
            session.endFromPeer(.daemonQuit)
        }
        for peer in peers.values { peer.close() }
        listener.stop()
    }

    private func accept(_ channel: VCPChannel) {
        let peer = PeerConnection(channel: channel, server: self)
        peers[ObjectIdentifier(peer)] = peer
        peer.start()
    }

    fileprivate func remove(peer: PeerConnection) {
        peers.removeValue(forKey: ObjectIdentifier(peer))
        // R-VCP-13 — peer disconnect terminates that peer's sessions.
        for id in peer.sessionIds {
            if let session = sessions.removeValue(forKey: id) {
                session.endFromPeer(.peerLost)
            }
        }
        onSessionsChanged?()
    }

    /// Public so an in-process caller (the HTTP MCP transport,
    /// `VoiceChatMCPServer`) can open sessions the same way VCP's
    /// `PeerConnection` does, without going through a socket.
    /// Throws when the caller asked for a debate seat it cannot have — an
    /// unknown room, or one already taken. Nothing is opened in that case.
    public func openSession(id: String, title: String?, host: String?, cwd: String?,
                            model: String? = nil, debate: DebateJoin? = nil) throws -> Session {
        let seat = try debate.map { join -> DebateSeat in
            guard let coordinator = DebateRegistry.shared.coordinator(join.roomID),
                  let seat = coordinator.room.seat(join.seat) else {
                // Let the registry phrase the refusal; it owns the wording.
                try DebateRegistry.shared.seat(RejectedSeat(), join: join)
                throw VCPError.debateSeatUnavailable("That debate seat is not available.")
            }
            return seat
        }
        let session = Session(id: id, title: title, hostName: host, cwd: cwd, model: model,
                              debateSeat: seat)
        if let debate {
            do {
                try DebateRegistry.shared.seat(session, join: debate)
            } catch {
                session.windowController.closeQuietly()
                throw error
            }
        }
        sessions[id] = session
        // True disposal: once the window actually closes, the session is
        // dropped from the registry and can no longer be reopened from the
        // menu bar, regardless of who or what ended it.
        session.onDisposed = { [weak self] sessionId in
            Task { @MainActor in self?.removeSession(sessionId) }
        }
        if let debate, let coordinator = DebateRegistry.shared.coordinator(debate.roomID),
           let index = coordinator.room.seats.firstIndex(where: { $0.key == debate.seat }) {
            // A debate seat is placed beside its opponent and given its own
            // voice, so the two sides are told apart by ear as well as by eye.
            let deliveries = DebateVoices.deliveries(for: coordinator.room.seats,
                                                     available: DebateVoices.installed())
            if index < deliveries.count { session.applyDelivery(deliveries[index]) }
            session.show(seatIndex: index, of: coordinator.room.seats.count)
        } else {
            session.show()
        }
        onSessionsChanged?()
        return session
    }

    public func session(_ id: String) -> Session? { sessions[id] }

    public func closeSession(_ id: String, reason: EndReason) {
        guard let session = sessions[id] else { return }
        session.endFromPeer(reason)
    }

    private func removeSession(_ id: String) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        onSessionsChanged?()
    }

    public func focus(sessionId: String) {
        sessions[sessionId]?.windowController.present()
    }
}

// MARK: - One connected peer

@MainActor
final class PeerConnection {
    private let channel: VCPChannel
    private unowned let server: DaemonServer
    private(set) var sessionIds: Set<String> = []
    private var didHello = false

    init(channel: VCPChannel, server: DaemonServer) {
        self.channel = channel
        self.server = server
    }

    func start() {
        channel.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handle(frame) }
        }
        channel.onClose = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.server.remove(peer: self)
            }
        }
        channel.resume()
    }

    func close() { channel.close() }

    // MARK: Dispatch

    private func handle(_ frame: VCPIncoming) {
        guard case .request(let id, let method, let params) = frame else { return }

        // R-VCP-3 — the first message must be `hello`.
        guard didHello || method == .hello else {
            reply(id: id, error: VCPError(code: VCPError.Code.invalidRequest,
                                          message: "hello_expected"))
            channel.close()
            return
        }

        do {
            switch method {
            case .hello:        try handleHello(id: id, params: params)
            case .ping:         try send(VCPCodec.response(id: id, result: EmptyPayload()))
            case .sessionOpen:  try handleSessionOpen(id: id, params: params)
            case .turnAwait:    try handleTurnAwait(id: id, params: params)
            case .turnCancel:   try handleTurnCancel(id: id, params: params)
            case .sessionClose: try handleSessionClose(id: id, params: params)
            case .sessionRoots: try handleSessionRoots(id: id, params: params)
            case .sessionEnded, .turnProgress:
                reply(id: id, error: VCPError(code: VCPError.Code.methodNotFound,
                                              message: "server_to_client_only"))
            }
        } catch {
            reply(id: id, error: VCPError(code: VCPError.Code.invalidRequest,
                                          message: "\(error)"))
        }
    }

    private func handleHello(id: Int, params: Data) throws {
        let hello = try VCPCodec.decodePayload(HelloParams.self, from: params)
        guard hello.vcpVersion == VCP.version else {          // R-VCP-4
            reply(id: id, error: .versionUnsupported(accepted: [VCP.version]))
            channel.close()
            return
        }
        didHello = true
        try send(VCPCodec.response(id: id,
                                   result: HelloResult(daemonVersion: server.daemonVersion)))
    }

    private func handleSessionOpen(id: Int, params: Data) throws {
        let open = try VCPCodec.decodePayload(SessionOpenParams.self, from: params)
        let session: Session
        do {
            session = try server.openSession(id: open.sessionId, title: open.title, host: open.host,
                                             cwd: open.cwd, model: open.model, debate: open.debate)
        } catch let error as VCPError {
            reply(id: id, error: error)
            return
        }
        sessionIds.insert(open.sessionId)

        session.onEnded = { [weak self] sessionId, reason in
            Task { @MainActor in self?.notifyEnded(sessionId, reason) }
        }
        session.onProgress = { [weak self] sessionId, phase in
            Task { @MainActor in self?.notifyProgress(sessionId, phase) }
        }

        let turnId = session.firstTurnId
        try send(VCPCodec.response(id: id,
                                   result: SessionOpenResult(sessionId: open.sessionId,
                                                             turnId: turnId)))
    }

    private func handleTurnAwait(id: Int, params: Data) throws {
        let request = try VCPCodec.decodePayload(TurnAwaitParams.self, from: params)
        guard let session = server.session(request.sessionId) else {
            reply(id: id, error: .unknownSession)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                session.updateIdentity(model: request.model)
                let result = try await session.coordinator.awaitTurn(request) { markdown in
                    Task { @MainActor in session.present(response: markdown) }
                }
                try self.send(VCPCodec.response(id: id, result: result))
            } catch let error as VCPError {
                self.reply(id: id, error: error)
            } catch {
                self.reply(id: id, error: VCPError(code: VCPError.Code.invalidRequest,
                                                   message: "\(error)"))
            }
        }
    }

    private func handleTurnCancel(id: Int, params: Data) throws {
        let request = try VCPCodec.decodePayload(TurnRefParams.self, from: params)
        guard let session = server.session(request.sessionId) else {
            reply(id: id, error: .unknownSession)
            return
        }
        Task { @MainActor in
            await session.coordinator.cancelTurn(request.turnId)
            session.endFromPeer(.hostCancelled)
        }
        try send(VCPCodec.response(id: id, result: EmptyPayload()))
    }

    private func handleSessionRoots(id: Int, params: Data) throws {
        let request = try VCPCodec.decodePayload(SessionRootsParams.self, from: params)
        guard let session = server.session(request.sessionId) else {
            reply(id: id, error: .unknownSession)
            return
        }
        session.setRoots(request.roots)
        try send(VCPCodec.response(id: id, result: EmptyPayload()))
    }

    private func handleSessionClose(id: Int, params: Data) throws {
        let request = try VCPCodec.decodePayload(SessionCloseParams.self, from: params)
        sessionIds.remove(request.sessionId)
        server.closeSession(request.sessionId, reason: request.reason)
        try send(VCPCodec.response(id: id, result: EmptyPayload()))
    }

    // MARK: Notifications

    private func notifyEnded(_ sessionId: String, _ reason: EndReason) {
        sessionIds.remove(sessionId)
        try? send(VCPCodec.notification(method: .sessionEnded,
                                        params: SessionEndedParams(sessionId: sessionId,
                                                                   reason: reason)))
    }

    private func notifyProgress(_ sessionId: String, _ phase: TurnProgressParams.Phase) {
        try? send(VCPCodec.notification(
            method: .turnProgress,
            params: TurnProgressParams(sessionId: sessionId, turnId: "", phase: phase)))
    }

    // MARK: Plumbing

    private func send(_ data: Data) throws { try channel.send(data) }

    private func reply(id: Int, error: VCPError) {
        try? send(VCPCodec.failure(id: id, error: error))
    }
}
