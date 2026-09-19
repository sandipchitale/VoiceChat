import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Adapted from the swift-sdk's own reference adapter,
// `Sources/MCPConformance/Server/HTTPApp.swift` (an executable-only target,
// so it can't be imported — this is a close copy, not a fork of independent
// logic). The one substantive addition over the reference: an `onClose` hook
// per session, since the reference has no notion of a side effect (here, a
// VoiceChat conversation window) that must be torn down when an HTTP session
// ends — without it, an abandoned web client would leave its window open
// forever.

actor HTTPApp {
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var endpoint: String
        var sessionTimeout: TimeInterval
        var retryInterval: Int?

        init(
            host: String = "127.0.0.1",
            port: Int = 3000,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = nil
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
            self.retryInterval = retryInterval
        }
    }

    /// Builds one `Server` per new `Mcp-Session-Id`, plus the cleanup to run
    /// when that session ends for any reason (explicit `DELETE`, idle
    /// timeout, or the whole app shutting down) — for VoiceChat, this is
    /// where the conversation's window actually gets asked to close.
    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws
        -> (server: Server, onClose: @Sendable () async -> Void)

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var cleanupTask: Task<Void, Never>?
    private var sessions: [String: SessionContext] = [:]

    nonisolated let logger: Logger

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let onClose: @Sendable () async -> Void
        let createdAt: Date
        var lastAccessedAt: Date
    }

    init(
        configuration: Configuration = Configuration(),
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline
        self.logger = logger ?? Logger(
            label: "mcp.http.app",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    // MARK: - Lifecycle

    /// Binds and starts accepting connections, then returns — the accept
    /// loop keeps running in the background via NIO's own event loop, not by
    /// this call blocking. That matters once the app can be toggled on and
    /// off repeatedly (from a menu item, not just once at launch): a caller
    /// needs `start()` to actually report a bind failure (e.g. the port is
    /// already taken) rather than never returning either way.
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        logger.info(
            "Starting MCP HTTP application",
            metadata: [
                "host": "\(configuration.host)",
                "port": "\(configuration.port)",
                "endpoint": "\(configuration.endpoint)",
            ]
        )

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel
        cleanupTask = Task { await sessionCleanupLoop() }
    }

    /// Stops the HTTP application gracefully, closing all sessions — this is
    /// how every in-flight HTTP-originated conversation window gets asked to
    /// close before the daemon quits, mirroring VCP's own `DaemonServer.stop()`.
    /// Fully tears down the event loop group and the cleanup loop too, so a
    /// later `start()` (toggling back on) begins from a clean slate rather
    /// than leaking a thread pool and a cleanup task per cycle.
    func stop() async {
        await closeAllSessions()
        cleanupTask?.cancel()
        cleanupTask = nil
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
        logger.info("MCP HTTP application stopped")
    }

    // MARK: - Request Routing

    var endpoint: String { configuration.endpoint }

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                await closeSession(sessionID)
            }

            return response
        }

        if request.method.uppercased() == "POST",
            let body = request.body,
            Self.isInitializeRequest(body)
        {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    /// The SDK's own equivalent (`JSONRPCMessageKind`) is `package`-scoped and
    /// invisible outside the swift-sdk package, so this is a minimal
    /// reimplementation of just the one check `handleHTTPRequest` needs.
    private static func isInitializeRequest(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return (json["method"] as? String) == "initialize"
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger
        )

        do {
            let (server, onClose) = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                onClose: onClose,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            if case .error = response {
                await closeSession(sessionID)
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.onClose()
        await session.transport.disconnect()
        logger.info("Closed session", metadata: ["sessionID": "\(sessionID)"])
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
    }

    private func sessionCleanupLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { break }

            let now = Date()
            let expired = sessions.filter { _, context in
                now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout
            }

            for (sessionID, _) in expired {
                logger.info("Session expired", metadata: ["sessionID": "\(sessionID)"])
                await closeSession(sessionID)
            }
        }
    }
}

// MARK: - NIO HTTP Handler

/// Thin NIO adapter that converts between NIO HTTP types and the framework-agnostic
/// `HTTPRequest`/`HTTPResponse` types, delegating all logic to `HTTPApp`.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: HTTPApp

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var requestState: RequestState?

    init(app: HTTPApp) {
        self.app = app
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            Task { @MainActor in
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await app.endpoint

        guard path == endpoint else {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return
        }

        let httpRequest = makeHTTPRequest(from: state)
        let response = await app.handleHTTPRequest(httpRequest)
        await writeResponse(response, version: head.version, context: context)
    }

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
            let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))

        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // Stream ended with error — close connection.
            }

            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }

                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
