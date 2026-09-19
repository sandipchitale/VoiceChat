import Foundation

// Spec §3 — the MCP server's side of VCP: request/response correlation over
// one channel, plus delivery of daemon notifications.

public actor VCPClient {
    private let channel: VCPChannel
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var closeError: Error?
    private var isClosed = false

    public private(set) var notifications: AsyncStream<VCPIncoming>
    private let notify: AsyncStream<VCPIncoming>.Continuation

    public init(channel: VCPChannel) {
        self.channel = channel
        var cont: AsyncStream<VCPIncoming>.Continuation!
        self.notifications = AsyncStream { cont = $0 }
        self.notify = cont

        channel.onFrame = { [weak self] frame in
            guard let self else { return }
            Task { await self.deliver(frame) }
        }
        channel.onClose = { [weak self] error in
            guard let self else { return }
            Task { await self.handleClose(error) }
        }
        channel.resume()
    }

    // MARK: Requests

    public func call<P: Encodable, R: Decodable>(_ method: VCPMethod, _ params: P, as: R.Type) async throws -> R {
        let data = try await callRaw(method, params)
        return try VCPCodec.decodePayload(R.self, from: data)
    }

    public func callRaw<P: Encodable>(_ method: VCPMethod, _ params: P) async throws -> Data {
        if isClosed { throw closeError ?? VCPSocketError.writeFailed(EPIPE) }
        let id = nextId
        nextId += 1
        let frame = try VCPCodec.request(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try channel.send(frame) }
            catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    public func send<P: Encodable>(notification method: VCPMethod, _ params: P) throws {
        try channel.send(try VCPCodec.notification(method: method, params: params))
    }

    public func close() {
        channel.close()
    }

    // MARK: Delivery

    private func deliver(_ frame: VCPIncoming) {
        switch frame {
        case .response(let id, let result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case .failure(let id, let error):
            pending.removeValue(forKey: id)?.resume(throwing: error)
        case .notification, .request:
            notify.yield(frame)
        }
    }

    private func handleClose(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        closeError = error ?? VCPSocketError.writeFailed(EPIPE)
        // R-VCP-14 / R-MCP-16 — never leave a caller hanging on a dead socket.
        for (_, continuation) in pending {
            continuation.resume(throwing: closeError!)
        }
        pending.removeAll()
        notify.finish()
    }
}
