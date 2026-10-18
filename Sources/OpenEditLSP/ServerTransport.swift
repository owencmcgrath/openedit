import Foundation

/// Byte transport between the client and one language server process
/// (ARCHITECTURE.md component map: LSP client). Delivers inbound JSON-RPC
/// messages on the main actor and ships outbound frames to the server's
/// stdin. `start()` begins delivery; `close()` tears everything down.
@MainActor
public protocol ServerTransport: AnyObject {
    /// Complete JSON-RPC envelopes decoded from the server's stdout.
    var onMessage: ((JSONRPCMessage) -> Void)? { get set }

    /// The stream ended (EOF, malformed framing, or `close()`).
    var onClosed: ((Error?) -> Void)? { get set }

    /// Begin reading. Idempotent.
    func start()

    /// Write one message. Order is the caller's responsibility (single
    /// enqueue per message); the transport preserves order.
    func send(_ message: JSONRPCMessage) throws

    /// Close only the write end (stdin), signaling EOF to the server without
    /// terminating it. Graceful shutdown uses this after `exit` so the server
    /// can drain its input and exit on its own.
    func closeWriteEnd()

    /// Stop reading and writing, release the process handles.
    func close()
}

/// Real transport over `Process` pipes. The server runs with the app's
/// inherited environment; only a *resolved absolute path* is launched
/// (ARCHITECTURE.md 5.6: resolution is `LanguageServerLocator`'s job).
///
/// Read mechanics: `readabilityHandler` hands stdout chunks to a serial queue
/// that owns the frame decoder, and complete messages hop to the main actor,
/// preserving byte order throughout.
public final class ProcessTransport: ServerTransport {
    /// Optional append-only stderr sink for `--lsp-log` (ARCHITECTURE.md 5.1).
    /// Bound at spawn: one shared server per language (§5.5) means the sink the
    /// process started with is the sink it keeps; later CLI requests do not
    /// re-scope a running server.
    private let stderrLogURL: URL?

    nonisolated private static let stderrLogLock = NSLock()

    private let executablePath: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let readQueue = DispatchQueue(label: "OpenEdit.LSP.transport.read")
    private let decoder = JSONRPCFrameDecoder()
    private var stderrBuffer = Data()
    private var started = false

    public var onMessage: ((JSONRPCMessage) -> Void)?
    public var onClosed: ((Error?) -> Void)?

    /// `environment` overrides the inherited environment when non-nil; the app
    /// leaves it nil so servers see the same environment the app did, while
    /// tests use it to point at a per-test config.
    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        stderrLogURL: URL? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.stderrLogURL = stderrLogURL
        decoder.onMessage = { [weak self] body in
            guard let message = try? JSONRPCMessage.parse(body) else {
                self?.close(with: LSPError.protocolError("message body is not a parseable JSON-RPC envelope"))
                return
            }
            Task { @MainActor [weak self] in
                self?.onMessage?(message)
            }
        }
        decoder.onMalformed = { [weak self] reason in
            self?.close(with: LSPError.protocolError("malformed framing: \(reason)"))
        }
    }

    nonisolated private static func appendStderr(_ text: String, to url: URL?) {
        guard let url, let data = text.data(using: .utf8) else { return }
        stderrLogLock.lock()
        defer { stderrLogLock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    public func start() {
        guard !started else { return }
        started = true

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.readQueue.async { [decoder = self.decoder] in
                decoder.append(chunk)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // The sink is captured at start, not read per chunk: the spawn-time
            // sink is the process's sink for its whole lifetime (§5.1).
            let stderrSink = self?.stderrLogURL
            self?.readQueue.async { [weak self] in
                self?.stderrBuffer.append(chunk)
                if let stderr = String(data: chunk, encoding: .utf8) {
                    NSLog("OpenEdit LSP stderr: %@", stderr)
                    Self.appendStderr(stderr, to: stderrSink)
                }
            }
        }

        do {
            try process.run()
        } catch {
            onClosed?(LSPError.launchFailed("\(executablePath): \(error)"))
            return
        }

        process.terminationHandler = { [weak self] process in
            let reason: Error? = process.terminationStatus == 0 ? nil : LSPError.terminated
            Task { @MainActor [weak self] in
                self?.close(with: reason)
            }
        }
    }

    public func send(_ message: JSONRPCMessage) throws {
        guard process.isRunning else {
            throw LSPError.notRunning
        }
        let frame = JSONRPCFraming.encode(message: message)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: frame)
        } catch {
            close(with: error)
            throw LSPError.terminated
        }
    }

    public func closeWriteEnd() {
        try? inputPipe.fileHandleForWriting.close()
    }

    public func close() {
        close(with: nil)
    }

    private func close(with error: Error?) {
        guard started else {
            onClosed?(error)
            return
        }
        started = false
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()

        if process.isRunning {
            process.terminate()
        }
        onClosed?(error)
    }
}
