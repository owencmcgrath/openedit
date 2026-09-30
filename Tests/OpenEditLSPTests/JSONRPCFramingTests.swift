import Foundation
import Testing
@testable import OpenEditLSP

@Suite struct JSONRPCFramingTests {
    @Test func encodesContentLengthHeaderAndBody() throws {
        let message = JSONRPCMessage.request(1, "initialize", params: .object(["rootUri": .null]))
        let frame = JSONRPCFraming.encode(message: message)
        let text = String(decoding: frame, as: UTF8.self)

        #expect(text.hasPrefix("Content-Length: "))
        let parts = text.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        let declared = Int(parts[0].replacingOccurrences(of: "Content-Length: ", with: ""))
        #expect(declared == parts[1].utf8.count)
        #expect(parts[1].contains("\"method\":\"initialize\""))
    }

    @Test func decodesWholeFrame() {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#.utf8)
        var decoded: [Data] = []
        let decoder = JSONRPCFrameDecoder()
        decoder.onMessage = { decoded.append($0) }

        decoder.append(JSONRPCFraming.encode(body: body))

        #expect(decoded == [body])
    }

    @Test func reassemblesFrameSplitAcrossChunks() {
        let body = Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)
        let frame = JSONRPCFraming.encode(body: body)
        var decoded: [Data] = []
        let decoder = JSONRPCFrameDecoder()
        decoder.onMessage = { decoded.append($0) }

        // Byte-by-byte is the worst case the transport can see.
        for byte in frame {
            decoder.append(Data([byte]))
        }

        #expect(decoded == [body])
    }

    @Test func decodesMultipleFramesInOneChunk() {
        let bodies = [
            Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8),
            Data(#"{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8),
        ]
        var decoded: [Data] = []
        let decoder = JSONRPCFrameDecoder()
        decoder.onMessage = { decoded.append($0) }

        decoder.append(bodies.map { JSONRPCFraming.encode(body: $0) }.reduce(Data(), +))

        #expect(decoded == bodies)
    }

    @Test func reportsMalformedLength() {
        var reasons: [String] = []
        let decoder = JSONRPCFrameDecoder()
        decoder.onMalformed = { reasons.append($0) }

        decoder.append(Data("Content-Length: not-a-number\r\n\r\n{}".utf8))

        #expect(reasons.count == 1)
    }

    @Test func reportsMissingContentLength() {
        var reasons: [String] = []
        let decoder = JSONRPCFrameDecoder()
        decoder.onMalformed = { reasons.append($0) }

        decoder.append(Data("Content-Type: application/json\r\n\r\n{}".utf8))

        #expect(reasons.count == 1)
    }

    @Test func reportsOversizedDeclaredLength() {
        var reasons: [String] = []
        let decoder = JSONRPCFrameDecoder()
        decoder.onMalformed = { reasons.append($0) }

        decoder.append(Data("Content-Length: 999999999999\r\n\r\n".utf8))

        #expect(reasons.count == 1)
    }

    @Test func toleratesExtraHeaderFields() {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        var decoded: [Data] = []
        let decoder = JSONRPCFrameDecoder()
        decoder.onMessage = { decoded.append($0) }

        decoder.append(Data("Content-Length: \(body.count)\r\nContent-Type: application/json\r\n\r\n".utf8) + body)

        #expect(decoded == [body])
    }

    @Test func messageRoundTripsEnvelope() throws {
        let original = JSONRPCMessage.request(3, "textDocument/hover", params: .object([
            "textDocument": .object(["uri": .string("file:///tmp/a.py")]),
            "position": .object(["line": .number(NSNumber(value: 1)), "character": .number(NSNumber(value: 4))]),
        ]))

        let parsed = try JSONRPCMessage.parse(original.encoded())

        #expect(parsed.method == "textDocument/hover")
        #expect(parsed.id?.intValue == 3)
        #expect(parsed.params?["position"]?["line"]?.intValue == 1)
    }
}

@Suite struct FileURITests {
    @Test func encodesPathWithSpaces() {
        let url = URL(fileURLWithPath: "/tmp/My Documents/a.py")
        let uri = FileURI.make(from: url)
        #expect(uri == "file:///tmp/My%20Documents/a.py")
        #expect(FileURI.fileURL(for: uri!)?.path == "/tmp/My Documents/a.py")
    }

    @Test func encodesNonASCIIName() {
        let url = URL(fileURLWithPath: "/tmp/héllo.py")
        let uri = FileURI.make(from: url)
        #expect(uri != nil)
        #expect(FileURI.fileURL(for: uri!)?.path == "/tmp/héllo.py")
    }

    @Test func rejectsNonFileURLs() {
        #expect(FileURI.make(from: URL(string: "https://example.com/a.py")!) == nil)
        #expect(FileURI.fileURL(for: "https://example.com/a.py") == nil)
    }
}
