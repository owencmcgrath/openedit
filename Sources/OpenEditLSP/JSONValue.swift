import Foundation

/// Minimal JSON model for LSP payloads (ARCHITECTURE.md component map: LSP
/// client). Foundation's `JSONSerialization` is the only parser; this enum
/// makes decoded values `Equatable`/`Sendable` so client state can hold and
/// compare them. Numbers keep their `NSNumber` form so integer fields
/// (`version`, `severity`, ranges) survive a decode→encode round trip without
/// drifting to `Double`.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(NSNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return fromAny(raw)
    }

    /// Serialized message body (without JSON-RPC framing).
    public func encoded() -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        if #available(macOS 10.15, *) {
            options.insert(.withoutEscapingSlashes)
        }
        return (try? JSONSerialization.data(withJSONObject: anyValue, options: options)) ?? Data("null".utf8)
    }

    // MARK: Construction from JSONSerialization output

    private static func fromAny(_ raw: Any) -> JSONValue {
        switch raw {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // Exclude Bool, which bridges to NSNumber on Apple platforms.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(fromAny))
        case let object as [String: Any]:
            return .object(object.mapValues(fromAny))
        default:
            return .null
        }
    }

    // MARK: Back to JSONSerialization input

    private var anyValue: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .number(value):
            return value
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.anyValue)
        case let .object(values):
            return values.mapValues(\.anyValue)
        }
    }

    // MARK: Convenience accessors for known-shape payloads

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case let .number(value) = self { return value.intValue }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
