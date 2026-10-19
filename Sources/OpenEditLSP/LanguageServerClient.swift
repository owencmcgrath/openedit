import Foundation

/// Lifecycle and protocol client for one language server process
/// (ARCHITECTURE.md 5.5). Owns the `initialize`/`initialized` handshake,
/// full-document `didOpen`/`didChange`/`didClose` payloads, request/response
/// correlation with stale-response rejection, and the idle-linger window that
/// keeps the process alive between documents.
///
/// Everything runs on the main actor: the app's document flow is main-actor,
/// and the transport hops server output here. A server failure never throws
/// across an editing path — failures surface as state (`.failed`) plus
/// `onTerminated`, and pending requests fail in place.
@MainActor
public final class LanguageServerClient {
    public enum State: Equatable {
        case notLaunched
        case initializing
        case running
        case shuttingDown
        case terminated
        case failed(String)
    }

    /// Set once to learn about ungraceful ends (crash, launch failure,
    /// protocol failure). Not called for a deliberate `shutdownAndExit`.
    public var onTerminated: ((Error) -> Void)?

    /// Server-initiated notifications, e.g. `textDocument/publishDiagnostics`.
    public var onServerNotification: ((JSONRPCMessage) -> Void)?

    public private(set) var state: State = .notLaunched
    public private(set) var serverCapabilities: JSONValue?

    /// How long the process lingers after the last document closes
    /// (ARCHITECTURE.md 5.5: 5 minutes; short in tests).
    public var lingerInterval: TimeInterval

    /// Documents currently open, tracked per §5.5: URI, language ID, and the
    /// most recent monotonically increasing version.
    public private(set) var openDocuments: [String: TrackedDocument] = [:]

    public struct TrackedDocument: Equatable {
        public let uri: String
        public let languageID: String
        public let version: Int
    }

    private let transport: ServerTransport
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var lingerTask: Task<Void, Never>?

    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    public init(transport: ServerTransport, lingerInterval: TimeInterval = 5 * 60) {
        self.transport = transport
        self.lingerInterval = lingerInterval
        transport.onMessage = { [weak self] message in
            self?.handleInbound(message)
        }
        transport.onClosed = { [weak self] error in
            self?.handleClosed(error)
        }
    }

    // MARK: - Lifecycle

    /// Spawn the server and complete the handshake. Returns the server's
    /// `capabilities` object. Throws on spawn or handshake failure, in which
    /// case the state becomes `.failed` and the transport is closed.
    public func launch() async throws {
        guard state == .notLaunched else {
            throw LSPError.protocolError("launch attempted in state \(state)")
        }
        state = .initializing
        transport.start()

        let params = JSONValue.object([
            "processId": .number(NSNumber(value: ProcessInfo.processInfo.processIdentifier)),
            // §5.5 originally said rootUri = the file's parent directory, but
            // LSP only accepts roots at initialize time and one process serves
            // every same-language file, scattered or not. Decided for #6: null
            // root — no workspace indexing for scattered single-file peeks.
            // (Recorded in ARCHITECTURE.md 5.5.)
            "rootUri": JSONValue.null,
            "capabilities": .object([:]),
        ])

        do {
            let result = try await sendRequest("initialize", params: params)
            serverCapabilities = result
            state = .running
            try transport.send(.notification("initialized", params: .object([:])))
        } catch {
            state = .failed("initialize failed: \(error)")
            transport.close()
            throw error
        }
    }

    public var isReady: Bool { state == .running }

    // MARK: - Requests and notifications (outbound)

    /// Send a request and await its response. Responses carrying an id with
    /// no pending entry are stale and dropped (`handleInbound`); a crashed or
    /// shut-down server fails every pending request via `handleClosed`.
    public func sendRequest(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        // Requests are legal only during and after the handshake. Before
        // launch, while shutting down, or once ended, the response could never
        // arrive — reject rather than await forever.
        guard state == .initializing || state == .running else {
            throw LSPError.notRunning
        }
        let id = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = PendingRequest(continuation: continuation)
            do {
                try transport.send(.request(id, method, params: params ?? .null))
            } catch {
                // Undeliverable — the response can never arrive, so fail in
                // place (resumed exactly once, here).
                if let pending = pendingRequests.removeValue(forKey: id) {
                    pending.continuation.resume(throwing: error)
                }
            }
        }
    }

    public func sendNotification(_ method: String, params: JSONValue) throws {
        try transport.send(.notification(method, params: params))
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Document tracking (§5.5)

    /// `textDocument/didOpen` with full content. Bumps the open-document
    /// count, which cancels any pending linger shutdown.
    public func didOpen(uri: String, languageID: String, version: Int, text: String) throws {
        guard isReady else {
            throw LSPError.notRunning
        }
        cancelLinger()
        openDocuments[uri] = TrackedDocument(uri: uri, languageID: languageID, version: version)
        try sendNotification(
            "textDocument/didOpen",
            params: .object([
                "textDocument": .object([
                    "uri": .string(uri),
                    "languageId": .string(languageID),
                    "version": .number(NSNumber(value: version)),
                    "text": .string(text),
                ]),
            ])
        )
    }

    /// `textDocument/didChange` with full-document sync ([Decided] §5.5):
    /// one change carrying the whole text and the new version.
    public func didChange(uri: String, version: Int, text: String) throws {
        guard let tracked = openDocuments[uri] else {
            throw LSPError.protocolError("didChange for unopened document \(uri)")
        }
        openDocuments[uri] = TrackedDocument(uri: uri, languageID: tracked.languageID, version: version)
        try sendNotification(
            "textDocument/didChange",
            params: .object([
                "textDocument": .object([
                    "uri": .string(uri),
                    "version": .number(NSNumber(value: version)),
                ]),
                "contentChanges": .array([
                    .object(["text": .string(text)]),
                ]),
            ])
        )
    }

    /// `textDocument/didClose`. When the last document closes, the linger
    /// timer starts; expiry runs the shutdown sequence.
    public func didClose(uri: String) throws {
        guard openDocuments[uri] != nil else {
            throw LSPError.protocolError("didClose for unopened document \(uri)")
        }
        openDocuments.removeValue(forKey: uri)
        try sendNotification(
            "textDocument/didClose",
            params: .object([
                "textDocument": .object(["uri": .string(uri)]),
            ])
        )
        if openDocuments.isEmpty {
            startLinger()
        }
    }

    // MARK: - Shutdown and idle linger

    /// Protocol shutdown: `shutdown` request, then `exit` notification, then
    /// EOF on stdin so the server drains and exits by itself. Bounded wait,
    /// then a terminating `close()` as backstop. Idempotent — a server that
    /// already died just drains, and every pending request is failed by
    /// `handleClosed`.
    public func shutdownAndExit() async {
        cancelLinger()
        guard state == .initializing || state == .running else {
            transport.close()
            return
        }
        state = .shuttingDown
        try? transport.send(.request(nextRequestID, "shutdown", params: .null))
        nextRequestID += 1
        try? transport.send(.notification("exit", params: .object([:])))
        // EOF, not terminate: the server must get to read the frames above and
        // exit(0) on its own; closing the transport outright would SIGTERM it
        // before it processes the shutdown sequence.
        transport.closeWriteEnd()

        let deadline = Date().addingTimeInterval(2)
        while state != .terminated && !isFailed && Date() < deadline {
            await Task.yield()
        }
        transport.close()
    }

    // MARK: - Inbound routing

    private func handleInbound(_ message: JSONRPCMessage) {
        if message.isResponse {
            // Responses carry numeric ids from this client's counter; an id
            // with no pending entry is stale (already drained or never sent)
            // and is ignored.
            guard case let .number(idNumber) = message.id,
                  let pending = pendingRequests[idNumber.intValue]
            else { return }
            pendingRequests.removeValue(forKey: idNumber.intValue)
            if let error = message.error {
                pending.continuation.resume(
                    throwing: LSPError.responseError(
                        code: error["code"]?.intValue ?? -1,
                        message: error["message"]?.stringValue ?? "unknown error"
                    )
                )
            } else {
                pending.continuation.resume(returning: message.result ?? .null)
            }
            return
        }

        switch message.method {
        case "textDocument/publishDiagnostics", "window/showMessage", "window/logMessage":
            onServerNotification?(message)
        case "exit":
            // Server-initiated exit (rare): treat as termination.
            transport.close()
        default:
            // Server requests (e.g. workspace/configuration) are not consumed
            // in v1; reply with a protocol error so the server is not left
            // hanging. Unknown server notifications are dropped.
            if message.isServerRequest, let id = message.id {
                try? transport.send(.failure(id: id, code: -32601, message: "method not supported: \(message.method ?? "?")"))
            }
        }
    }

    private func handleClosed(_ error: Error?) {
        lingerTask = nil
        let drained = pendingRequests
        pendingRequests.removeAll()
        for pending in drained.values {
            pending.continuation.resume(throwing: error ?? LSPError.terminated)
        }

        if state == .shuttingDown {
            state = .terminated
            return
        }
        guard state != .terminated else { return }
        if let error {
            state = .failed("\(error)")
            onTerminated?(error)
        } else {
            // Clean EOF without a shutdown sequence is still an end the
            // owner should learn about.
            state = .terminated
            onTerminated?(LSPError.terminated)
        }
    }

    // MARK: - Linger timer

    private func startLinger() {
        cancelLinger()
        guard lingerInterval > 0, isReady else { return }
        lingerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64((self?.lingerInterval ?? 0) * 1_000_000_000))
            } catch {
                return // cancelled — a document reopened in the window
            }
            await self?.shutdownAndExit()
        }
    }

    private func cancelLinger() {
        lingerTask?.cancel()
        lingerTask = nil
    }
}
