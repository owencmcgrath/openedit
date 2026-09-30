import Foundation

/// JSON-RPC message in the LSP wire format: a `jsonrpc`/`method`/`id`/`params`
/// or `result`/`error` envelope. Direction-agnostic — used for both outbound
/// requests/notifications and inbound responses/server notifications.
public struct JSONRPCMessage: Sendable, Equatable {
    public var method: String?
    public var id: JSONValue?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JSONValue?

    public init(method: String? = nil, id: JSONValue? = nil, params: JSONValue? = nil) {
        self.method = method
        self.id = id
        self.params = params
    }

    public static func request(_ id: Int, _ method: String, params: JSONValue) -> JSONRPCMessage {
        JSONRPCMessage(method: method, id: .number(NSNumber(value: id)), params: params)
    }

    public static func notification(_ method: String, params: JSONValue) -> JSONRPCMessage {
        JSONRPCMessage(method: method, params: params)
    }

    public static func success(id: JSONValue, _ result: JSONValue) -> JSONRPCMessage {
        var message = JSONRPCMessage()
        message.id = id
        message.result = result
        return message
    }

    public static func failure(id: JSONValue, code: Int, message: String) -> JSONRPCMessage {
        var message_ = JSONRPCMessage()
        message_.id = id
        message_.error = .object([
            "code": .number(NSNumber(value: code)),
            "message": .string(message),
        ])
        return message_
    }

    public var isResponse: Bool { method == nil && id != nil }
    public var isNotification: Bool { method != nil && id == nil }
    public var isServerRequest: Bool { method != nil && id != nil }

    // MARK: Envelope encode/decode

    public func encoded() -> Data {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        if let method { object["method"] = .string(method) }
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        if let result { object["result"] = result }
        if let error { object["error"] = error }
        return JSONValue.object(object).encoded()
    }

    public static func parse(_ data: Data) throws -> JSONRPCMessage {
        guard case let .object(object) = try JSONValue.parse(data) else {
            throw LSPError.protocolError("message body is not a JSON object")
        }
        var message = JSONRPCMessage()
        message.method = object["method"]?.stringValue
        message.id = object["id"]
        message.params = object["params"]
        message.result = object["result"]
        message.error = object["error"]
        return message
    }
}

/// Errors surfaced by the LSP client and transport.
public enum LSPError: Error, Equatable {
    case protocolError(String)
    case launchFailed(String)
    case terminated
    case responseError(code: Int, message: String)
    case notRunning
}
