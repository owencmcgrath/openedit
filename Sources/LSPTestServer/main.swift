import Foundation

/// Controlled language server for OpenEdit's LSP client tests (issue #6
/// Checkpoint A acceptance). Foundation-only, independently implemented
/// framing — the tests must not depend on the production client for the
/// server side of the wire.
///
/// Configuration comes from the JSON file at `OPENEDIT_TEST_LSP_CONFIG`:
///
/// ```json
/// {
///   "logPath": "/tmp/server.log",
///   "mode": "standard" | "malformed" | "crash",
///   "garbageBeforeResponse": false,
///   "diagnostics": {
///     "message": "syntax error", "severity": 1,
///     "startLine": 0, "startCharacter": 0, "endLine": 0, "endCharacter": 5
///   },
///   "hover": { "contents": "hover text", "delayMs": 0 }
/// }
/// ```
///
/// Behaviors:
/// - All modes: every inbound and outbound envelope is logged to `logPath` as
///   one JSON line `{"dir":"in"|"out", ...envelope}` — tests assert exact
///   order and payloads from this log.
/// - `standard`: initialize → capabilities response; shutdown → null result;
///   exit → exit(0). Full-didOpen/didChange/didClose are accepted silently.
/// - `diagnostics` (or a `diagnostics` object in any mode): after each
///   didOpen/didChange, push `textDocument/publishDiagnostics` with the
///   configured content.
/// - `hover`: answer `textDocument/hover` with the configured contents after
///   an optional delay (stale-response testing).
/// - `malformed`: write `garbage` bytes before the initialize response (and
///   before every response when `garbageBeforeResponse` is true).
/// - `crash`: `exit(1)` ungracefully on the first didOpen (or immediately at
///   initialize when no didOpen is configured to trigger it).
///
/// Exit: on stdin EOF, or after the exit notification (status 0), or crash
/// mode (status 1).
let configPath = ProcessInfo.processInfo.environment["OPENEDIT_TEST_LSP_CONFIG"]
    ?? "openedit-test-server-missing-config.json"

struct TestServerConfig: Codable {
    var logPath: String
    var mode: String = "standard"
    var garbageBeforeResponse: Bool = false
    var diagnostics: Diagnostics?
    var hover: Hover?

    struct Diagnostics: Codable {
        var message: String = "test diagnostic"
        var severity: Int = 1
        var startLine: Int = 0
        var startCharacter: Int = 0
        var endLine: Int = 0
        var endCharacter: Int = 0

        // Synthesized Decodable does not honor property defaults for missing
        // keys, and tests pass only the fields they care about.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decodeIfPresent(String.self, forKey: .message) ?? "test diagnostic"
            severity = try container.decodeIfPresent(Int.self, forKey: .severity) ?? 1
            startLine = try container.decodeIfPresent(Int.self, forKey: .startLine) ?? 0
            startCharacter = try container.decodeIfPresent(Int.self, forKey: .startCharacter) ?? 0
            endLine = try container.decodeIfPresent(Int.self, forKey: .endLine) ?? 0
            endCharacter = try container.decodeIfPresent(Int.self, forKey: .endCharacter) ?? 0
        }

    }

    struct Hover: Codable {
        var contents: String = "test hover"
        var delayMs: Int = 0

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contents = try container.decodeIfPresent(String.self, forKey: .contents) ?? "test hover"
            delayMs = try container.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
        }

    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logPath = try container.decode(String.self, forKey: .logPath)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "standard"
        garbageBeforeResponse = try container.decodeIfPresent(Bool.self, forKey: .garbageBeforeResponse) ?? false
        diagnostics = try container.decodeIfPresent(Diagnostics.self, forKey: .diagnostics)
        hover = try container.decodeIfPresent(Hover.self, forKey: .hover)
    }

}

guard let configFileData = FileManager.default.contents(atPath: configPath) else {
    FileHandle.standardError.write(Data("lsp-test-server: cannot read \(configPath)\n".utf8))
    exit(2)
}
let config: TestServerConfig
do {
    config = try JSONDecoder().decode(TestServerConfig.self, from: configFileData)
} catch {
    FileHandle.standardError.write(Data("lsp-test-server: bad config \(configPath): \(error)\n".utf8))
    exit(2)
}

let logURL = URL(fileURLWithPath: config.logPath)
let logLock = NSLock()
// One handle for the process lifetime: created up front so every append goes
// through the seekToEnd path. (Writing the first entry with
// `Data.write(to:options:.atomic)` omits the trailing newline, gluing entry 1
// to entry 2 into one line that JSONL readers then drop.)
let logHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
    }
    return try? FileHandle(forWritingTo: logURL)
}()

func log(_ direction: String, _ object: [String: Any]) {
    var entry = object
    entry["dir"] = direction
    guard let line = try? JSONSerialization.data(withJSONObject: entry, options: [.fragmentsAllowed]) else { return }
    logLock.lock()
    defer { logLock.unlock() }
    guard let handle = logHandle else { return }
    handle.seekToEndOfFile()
    handle.write(line)
    handle.write(Data("\n".utf8))
}

let inputPipe = FileHandle.standardInput
let outputHandle = FileHandle.standardOutput

func send(_ object: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return }
    log("out", object)
    outputHandle.write(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
    outputHandle.write(body)
}

func sendGarbage() {
    let garbage = Data([
        0x54, 0x48, 0x49, 0x53, 0x2D, 0x49, 0x53, 0x2D, 0x4E, 0x4F, 0x54,
        0x2D, 0x41, 0x2D, 0x46, 0x52, 0x41, 0x4D, 0x45, 0x01, 0x02, 0x03,
    ])
    log("out", ["garbage": true])
    outputHandle.write(garbage)
}

var diagnosticsSent = false

func maybeSendDiagnostics(uri: String, version: Int?) {
    guard let diagnostics = config.diagnostics else { return }
    var payload: [String: Any] = ["uri": uri]
    if let version {
        payload["version"] = version
    }
    var items: [[String: Any]] = []
    if diagnostics.severity > 0 {
        items.append([
            "severity": diagnostics.severity,
            "message": diagnostics.message,
            "range": [
                "start": ["line": diagnostics.startLine, "character": diagnostics.startCharacter],
                "end": ["line": diagnostics.endLine, "character": diagnostics.endCharacter],
            ],
        ])
    }
    payload["diagnostics"] = items
    send(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": payload])
    diagnosticsSent = true
}

func handle(_ envelope: [String: Any]) -> Bool {
    // Returns false when the process should stop.
    let method = envelope["method"] as? String
    let id = envelope["id"]

    log("in", envelope)

    switch method {
    case "initialize":
        if config.garbageBeforeResponse || config.mode == "malformed" {
            sendGarbage()
        }
        send([
            "jsonrpc": "2.0",
            "id": id as Any? ?? NSNull(),
            "result": [
                "capabilities": [
                    "textDocumentSync": 1,
                    "hoverProvider": config.hover != nil,
                ],
            ],
        ])
        return true

    case "initialized":
        return true

    case "shutdown":
        send(["jsonrpc": "2.0", "id": id as Any? ?? NSNull(), "result": NSNull()])
        return true

    case "exit":
        exit(0)

    case "textDocument/didOpen", "textDocument/didChange":
        if config.mode == "crash" {
            log("out", ["crash": true])
            exit(1)
        }
        let openedDocument = (envelope["params"] as? [String: Any])?["textDocument"] as? [String: Any]
        maybeSendDiagnostics(
            uri: openedDocument?["uri"] as? String ?? "file:///test/diagnostic-target",
            version: openedDocument?["version"] as? Int
        )
        return true

    case "textDocument/didClose":
        return true

    case "textDocument/hover":
        guard let hover = config.hover else {
            send(["jsonrpc": "2.0", "id": id as Any? ?? NSNull(), "result": NSNull()])
            return true
        }
        if hover.delayMs > 0 {
            Thread.sleep(forTimeInterval: Double(hover.delayMs) / 1000)
        }
        send([
            "jsonrpc": "2.0",
            "id": id as Any? ?? NSNull(),
            "result": ["contents": hover.contents],
        ])
        return true

    default:
        // Unknown requests get a method-not-found response; notifications are
        // ignored. Keeps the server robust to whatever a test sends.
        if id != nil {
            send([
                "jsonrpc": "2.0",
                "id": id as Any? ?? NSNull(),
                "error": ["code": -32601, "message": "method not found"],
            ])
        }
        return true
    }
}

// Stream framing state.
var buffer = Data()
var pendingBodyLength: Int?

func processBuffer() {
    while true {
        if pendingBodyLength == nil {
            guard let terminatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<terminatorRange.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8) else { exit(3) }
            var contentLength: Int?
            // Split on newline scalars, not `split(separator: "\n")`: Swift
            // treats CRLF as one grapheme Character.
            for line in header.components(separatedBy: .newlines) {
                let pair = line.trimmingCharacters(in: .whitespaces)
                    .split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let length = contentLength else { exit(3) }
            pendingBodyLength = length
            buffer = buffer.subdata(in: terminatorRange.upperBound..<buffer.endIndex)
        }

        let length = pendingBodyLength!
        guard buffer.count >= length else { return }

        let body = buffer.prefix(length)
        buffer = buffer.subdata(in: body.endIndex..<buffer.endIndex)
        pendingBodyLength = nil

        guard let envelope = (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) as? [String: Any] else {
            exit(3)
        }
        if !handle(envelope) {
            exit(0)
        }
    }
}

// Blocking sequential read: simplest correct ordering for a test server.
// `availableData`, not `readData(ofLength:)`: the latter accumulates until it
// has the full requested length or EOF, which never happens on a live LSP
// stdin — the writer stays open — so a partial frame would deadlock the
// server even when complete frames are buffered.
while true {
    let chunk = inputPipe.availableData
    if chunk.isEmpty {
        break // EOF — parent closed stdin or exited
    }
    buffer.append(chunk)
    processBuffer()
}
exit(0)
