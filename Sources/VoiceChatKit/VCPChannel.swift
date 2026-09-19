import Foundation

// Spec §3.1 — AF_UNIX / SOCK_STREAM transport.
//
// Raw POSIX sockets rather than Network.framework: the endpoint is a plain
// filesystem path with fixed permissions, the peer uid must be checked
// (R-VCP-5), and the whole thing has to be inspectable with `nc`.

public enum VCPSocketError: Error, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32, String)
    case listenFailed(Int32)
    case connectFailed(Int32, String)
    case pathTooLong(String)
    case writeFailed(Int32)
    case peerRejected(uid: UInt32)
    case alreadyRunning
}

// MARK: - Channel

/// One connected socket. Frames arrive on `onFrame`; `onClose` fires exactly
/// once.
public final class VCPChannel: @unchecked Sendable {
    public let fd: Int32
    private let queue: DispatchQueue
    private var framer = LineFramer()
    private var readSource: DispatchSourceRead?
    private var closed = false
    private let lock = NSLock()

    public var onFrame: (@Sendable (VCPIncoming) -> Void)?
    public var onDecodeError: (@Sendable (Error) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?

    public init(fd: Int32, label: String) {
        self.fd = fd
        self.queue = DispatchQueue(label: "dev.sandipchitale.voicechat.vcp.\(label)")
        var flag: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
    }

    public func resume() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(self.fd)
        }
        readSource = source
        source.resume()
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &buf, buf.count)
        if n == 0 { finish(nil); return }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            finish(VCPSocketError.writeFailed(errno))
            return
        }
        do {
            for line in try framer.append(Data(buf[0..<n])) {
                do { onFrame?(try VCPCodec.decode(line: line)) }
                catch { onDecodeError?(error) }
            }
        } catch {
            // R-VCP-2 — an over-length frame closes the connection.
            finish(error)
        }
    }

    public func send(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw VCPSocketError.writeFailed(EPIPE) }
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw VCPSocketError.writeFailed(errno)
                }
                offset += written
            }
        }
    }

    public func close() { finish(nil) }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        readSource?.cancel()
        readSource = nil
        onClose?(error)
    }

    /// R-VCP-5 — reject a peer running as a different user.
    public func peerUID() -> UInt32? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let rc = withUnsafeMutablePointer(to: &cred) { ptr -> Int32 in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(len)) { raw in
                getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERCRED, raw, &len)
            }
        }
        guard rc == 0 else { return nil }
        return cred.cr_uid
    }
}

// MARK: - Address helper

enum UnixAddress {
    static func make(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw VCPSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                try body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

// MARK: - Listener (daemon side)

public final class VCPListener: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.sandipchitale.voicechat.vcp.listener")

    public var onPeer: (@Sendable (VCPChannel) -> Void)?

    public init(path: String) { self.path = path }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])          // §2.3 — container is 0700

        // R-VCP-6 — a stale socket file is unlinked and recreated.
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VCPSocketError.socketFailed(errno) }

        var addr = try UnixAddress.make(path: path)
        let bound = UnixAddress.withSockaddr(&addr) { sa, len in bind(fd, sa, len) }
        guard bound == 0 else {
            let e = errno; Darwin.close(fd)
            throw VCPSocketError.bindFailed(e, path)
        }

        // R-VCP-5 — socket is 0600.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let e = errno; Darwin.close(fd)
            throw VCPSocketError.listenFailed(e)
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        source = src
        src.resume()
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        let channel = VCPChannel(fd: client, label: "peer\(client)")
        if let uid = channel.peerUID(), uid != getuid() {
            channel.close()
            return
        }
        onPeer?(channel)
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        unlink(path)
    }
}

// MARK: - Dialler (MCP server side)

public enum VCPDialer {
    public static func connect(path: String) throws -> VCPChannel {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VCPSocketError.socketFailed(errno) }
        var addr = try UnixAddress.make(path: path)
        let rc = UnixAddress.withSockaddr(&addr) { sa, len in Darwin.connect(fd, sa, len) }
        guard rc == 0 else {
            let e = errno; Darwin.close(fd)
            throw VCPSocketError.connectFailed(e, path)
        }
        return VCPChannel(fd: fd, label: "client")
    }

    /// R-ARCH-3 — poll for the socket while the daemon starts, at most
    /// `timeout` seconds at 100 ms intervals.
    public static func connect(path: String, waitingUpTo timeout: TimeInterval) throws -> VCPChannel {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = VCPSocketError.connectFailed(ENOENT, path)
        repeat {
            do { return try connect(path: path) }
            catch { lastError = error; Thread.sleep(forTimeInterval: 0.1) }
        } while Date() < deadline
        throw lastError
    }
}
