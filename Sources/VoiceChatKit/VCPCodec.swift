import Foundation

// Spec §3.1/§3.2 — JSON Lines framing and JSON-RPC 2.0 envelope handling.

/// One decoded VCP frame. Payloads stay as raw JSON so the envelope can be
/// parsed before the method is known.
public enum VCPIncoming: Sendable {
    case request(id: Int, method: VCPMethod, params: Data)
    case notification(method: VCPMethod, params: Data)
    case response(id: Int, result: Data)
    case failure(id: Int, error: VCPError)

    public var requestId: Int? {
        switch self {
        case .request(let id, _, _), .response(let id, _), .failure(let id, _): return id
        case .notification: return nil
        }
    }
}

public enum VCPCodecError: Error, Equatable {
    case malformedLine(String)
    case lineTooLong(Int)
    case unknownMethod(String)
    case notAnObject
    case missingField(String)
}

public enum VCPCodec {

    // MARK: Encoding

    public static func request<P: Encodable>(id: Int, method: VCPMethod, params: P) throws -> Data {
        try line(["jsonrpc": "2.0", "id": id, "method": method.rawValue, "params": try object(params)])
    }

    public static func notification<P: Encodable>(method: VCPMethod, params: P) throws -> Data {
        try line(["jsonrpc": "2.0", "method": method.rawValue, "params": try object(params)])
    }

    public static func response<R: Encodable>(id: Int, result: R) throws -> Data {
        try line(["jsonrpc": "2.0", "id": id, "result": try object(result)])
    }

    public static func failure(id: Int?, error: VCPError) throws -> Data {
        var err: [String: Any] = ["code": error.code, "message": error.message]
        if let data = error.data, let encoded = try? object(data) { err["data"] = encoded }
        var env: [String: Any] = ["jsonrpc": "2.0", "error": err]
        env["id"] = id ?? NSNull()
        return try line(env)
    }

    // MARK: Decoding

    public static func decode(line data: Data) throws -> VCPIncoming {
        guard data.count <= VCP.maxLineBytes else { throw VCPCodecError.lineTooLong(data.count) }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let env = any as? [String: Any] else {
            throw VCPCodecError.notAnObject
        }

        let id = env["id"] as? Int

        if let errObj = env["error"] as? [String: Any] {
            guard let id else { throw VCPCodecError.missingField("id") }
            let code = errObj["code"] as? Int ?? VCPError.Code.invalidRequest
            let message = errObj["message"] as? String ?? "unknown"
            var payload: VCPError.ErrorData?
            if let d = errObj["data"] {
                payload = try? JSONDecoder().decode(
                    VCPError.ErrorData.self,
                    from: JSONSerialization.data(withJSONObject: d))
            }
            return .failure(id: id, error: VCPError(code: code, message: message, data: payload))
        }

        if let methodName = env["method"] as? String {
            guard let method = VCPMethod(rawValue: methodName) else {
                throw VCPCodecError.unknownMethod(methodName)
            }
            let params = try raw(env["params"])
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        if env.keys.contains("result") {
            guard let id else { throw VCPCodecError.missingField("id") }
            return .response(id: id, result: try raw(env["result"]))
        }

        throw VCPCodecError.malformedLine(String(decoding: data.prefix(200), as: UTF8.self))
    }

    public static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    // MARK: Helpers

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func raw(_ value: Any?) throws -> Data {
        guard let value, !(value is NSNull) else { return Data("{}".utf8) }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private static func line(_ env: [String: Any]) throws -> Data {
        // `.sortedKeys` keeps frames byte-stable, which makes codec round-trip
        // tests and log diffing straightforward.
        var data = try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= VCP.maxLineBytes else { throw VCPCodecError.lineTooLong(data.count) }
        data.append(0x0A)
        return data
    }
}

/// Accumulates bytes from a stream and yields complete newline-delimited
/// frames, enforcing the size cap of R-VCP-2.
public struct LineFramer: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<idx]
            buffer = buffer[buffer.index(after: idx)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        // A partial frame that already exceeds the cap can never become valid.
        if buffer.count > VCP.maxLineBytes {
            throw VCPCodecError.lineTooLong(buffer.count)
        }
        buffer = Data(buffer)
        return lines
    }
}
