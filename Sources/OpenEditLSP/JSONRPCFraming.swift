import Foundation

/// Byte-level JSON-RPC framing for LSP's stdio transport: a
/// `Content-Length: N\r\n` header block, a blank line, then `N` bytes of body.
public enum JSONRPCFraming {
    static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Cap on a single frame's header block; a stream that keeps sending
    /// header bytes without a terminator is garbage, not a slow sender.
    static let maximumHeaderLength = 4096

    /// Cap on a single frame's declared length; guards against a garbage byte
    /// stream claiming gigabytes. LSP bodies are document texts, so 64 MiB is
    /// generous.
    public static let maximumFrameLength = 64 * 1024 * 1024

    /// Encode one message into a complete frame.
    public static func encode(body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    public static func encode(message: JSONRPCMessage) -> Data {
        encode(body: message.encoded())
    }
}

/// Incremental frame decoder for a byte stream that may split frames across
/// chunks arbitrarily (one chunk: half a header; the next: several complete
/// frames). Feed `append(_:)`; finished message bodies come back through
/// `onMessage`, unusable streams through `onMalformed` (after which the
/// decoder refuses further input — the transport must drop the connection).
public final class JSONRPCFrameDecoder {
    public enum FailureReason: Error, Equatable {
        case malformed(String)
    }

    private var buffer = Data()
    private var expectedBodyLength: Int?
    private var failed = false

    /// Called on the thread that appends, for every complete message body.
    public var onMessage: ((Data) -> Void)?

    /// Called once, when framing becomes untrustworthy.
    public var onMalformed: ((String) -> Void)?

    public init() {}

    public func append(_ data: Data) {
        guard !failed else { return }
        buffer.append(data)

        while true {
            if expectedBodyLength == nil {
                switch Self.parseHeaderState(buffer) {
                case let .complete(length, remainder):
                    guard length <= JSONRPCFraming.maximumFrameLength else {
                        return fail("declared frame length \(length) exceeds maximum")
                    }
                    expectedBodyLength = length
                    buffer = remainder
                case .incomplete:
                    // Not enough bytes for a full header yet; wait for more.
                    return
                case let .malformed(reason):
                    return fail(reason)
                }
            }

            let length = expectedBodyLength!
            guard buffer.count >= length else { return }

            let body = buffer.prefix(length)
            buffer.removeFirst(length)
            expectedBodyLength = nil
            onMessage?(body)
        }
    }

    private func fail(_ reason: String) {
        failed = true
        buffer.removeAll()
        onMalformed?(reason)
    }

    private enum HeaderState {
        case complete(length: Int, remainder: Data)
        case incomplete
        case malformed(String)
    }

    /// Parses `Content-Length: N\r\n\r\n` from the front of `buffer`,
    /// returning the length and the bytes after the blank line. Tolerates
    /// additional header fields (e.g. Content-Type) and bare-`\n` separators.
    private static func parseHeaderState(_ buffer: Data) -> HeaderState {
        guard let terminatorRange = buffer.range(of: JSONRPCFraming.headerTerminator) else {
            if buffer.count > JSONRPCFraming.maximumHeaderLength {
                return .malformed("header block exceeds \(JSONRPCFraming.maximumHeaderLength) bytes without terminator")
            }
            return .incomplete
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<terminatorRange.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            return .malformed("header block is not UTF-8")
        }

        var contentLength: Int?
        // Note: Swift treats CRLF as one grapheme `Character`, so
        // `split(separator: "\n")` does not split CRLF-terminated header
        // fields. Split on the newline scalars instead.
        for line in header.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let pair = trimmed.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let parsed = Int(value), parsed >= 0 else {
                    return .malformed("bad Content-Length value '\(value)'")
                }
                contentLength = parsed
            }
        }

        guard let length = contentLength else {
            return .malformed("header block has no Content-Length")
        }
        return .complete(length: length, remainder: buffer.subdata(in: terminatorRange.upperBound..<buffer.endIndex))
    }
}
