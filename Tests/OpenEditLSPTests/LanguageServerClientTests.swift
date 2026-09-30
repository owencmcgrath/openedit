import Foundation
import Testing
@testable import OpenEditLSP

/// In-memory transport: records outbound messages and lets tests inject
/// inbound envelopes, so client behavior is asserted without a process.
@MainActor
private final class FakeTransport: ServerTransport {
    var onMessage: ((JSONRPCMessage) -> Void)?
    var onClosed: ((Error?) -> Void)?
    private(set) var sent: [JSONRPCMessage] = []
    private(set) var isClosed = false
    private(set) var startCount = 0

    func start() { startCount += 1 }
    func send(_ message: JSONRPCMessage) throws { sent.append(message) }
    func closeWriteEnd() {}
    func close() {
        isClosed = true
        // ProcessTransport.close always reports closure (EOF/termination);
        // mirror that so the client's shutdown sequence can complete.
        onClosed?(nil)
    }

    func deliver(_ message: JSONRPCMessage) { onMessage?(message) }
    func end(with error: Error?) { onClosed?(error) }

    /// All outbound messages with the given method.
    func sent(_ method: String) -> [JSONRPCMessage] {
        sent.filter { $0.method == method }
    }
}

@Suite @MainActor struct LanguageServerClientTests {
    /// Builds a client and drives its handshake to completion.
    private func launchedClient(
        lingerInterval: TimeInterval = 0.05
    ) async throws -> (LanguageServerClient, FakeTransport) {
        let transport = FakeTransport()
        let client = LanguageServerClient(transport: transport, lingerInterval: lingerInterval)
        let launch = Task { try await client.launch() }

        await waitUntil("initialize sent") { transport.sent("initialize").count == 1 }
        let initialize = transport.sent("initialize")[0]
        transport.deliver(.success(id: initialize.id!, .object(["capabilities": .object([:])])))
        try await launch.value
        return (client, transport)
    }

    @Test func handshakeSendsInitializeThenInitialized() async throws {
        let (client, transport) = try await launchedClient()

        #expect(client.isReady)
        #expect(transport.sent("initialize").count == 1)
        #expect(transport.sent("initialized").count == 1)
        // initialize is a request (id), initialized a notification (no id).
        #expect(transport.sent("initialize")[0].id != nil)
        #expect(transport.sent("initialized")[0].id == nil)
        // rootUri is null — the #6 decision recorded in ARCHITECTURE.md 5.5.
        #expect(transport.sent("initialize")[0].params?["rootUri"] == .null)
    }

    @Test func requestResponseCorrelation() async throws {
        let (client, transport) = try await launchedClient()

        let response = Task { try await client.sendRequest("custom/echo", params: .object(["x": .number(NSNumber(value: 5))])) }
        await waitUntil("request sent") { transport.sent("custom/echo").count == 1 }
        let request = transport.sent("custom/echo")[0]
        transport.deliver(.success(id: request.id!, .object(["x": .number(NSNumber(value: 5))])))

        let result = try await response.value
        #expect(result["x"]?.intValue == 5)
    }

    @Test func errorResponseThrows() async throws {
        let (client, transport) = try await launchedClient()

        let response = Task { try await client.sendRequest("custom/fail") }
        await waitUntil("request sent") { transport.sent("custom/fail").count == 1 }
        let request = transport.sent("custom/fail")[0]
        transport.deliver(JSONRPCMessage.failure(id: request.id!, code: -32601, message: "nope"))

        await #expect(throws: LSPError.responseError(code: -32601, message: "nope")) {
            try await response.value
        }
    }

    @Test func staleResponseIsIgnored() async throws {
        let (client, transport) = try await launchedClient()

        // A response for an id this client never sent must not crash or
        // disturb anything.
        transport.deliver(.success(id: .number(NSNumber(value: 9999)), .null))
        transport.deliver(JSONRPCMessage.failure(id: .number(NSNumber(value: 4242)), code: -1, message: "stale"))

        #expect(client.isReady)
        let ping = Task { try await client.sendRequest("custom/ping") }
        await waitUntil("ping sent") { transport.sent("custom/ping").count == 1 }
        transport.deliver(.success(id: transport.sent("custom/ping")[0].id!, .null))
        _ = try await ping.value
    }

    @Test func didOpenChangeClosePayloads() async throws {
        let (client, transport) = try await launchedClient()
        let uri = "file:///tmp/a.py"

        try client.didOpen(uri: uri, languageID: "python", version: 1, text: "x = 1\n")
        try client.didChange(uri: uri, version: 2, text: "x = 2\n")
        try client.didClose(uri: uri)

        let open = transport.sent("textDocument/didOpen")[0].params?["textDocument"]
        #expect(open?["uri"]?.stringValue == uri)
        #expect(open?["languageId"]?.stringValue == "python")
        #expect(open?["version"]?.intValue == 1)
        #expect(open?["text"]?.stringValue == "x = 1\n")

        let change = transport.sent("textDocument/didChange")[0].params
        #expect(change?["textDocument"]?["version"]?.intValue == 2)
        // Full-document sync: one change carrying the whole text.
        #expect(change?["contentChanges"]?.arrayValue?.count == 1)
        #expect(change?["contentChanges"]?.arrayValue?[0]["text"]?.stringValue == "x = 2\n")

        let close = transport.sent("textDocument/didClose")[0].params?["textDocument"]
        #expect(close?["uri"]?.stringValue == uri)

        #expect(client.openDocuments.isEmpty)
    }

    @Test func changeForUnopenedDocumentThrows() async throws {
        let (client, _) = try await launchedClient()
        #expect(throws: LSPError.protocolError("didChange for unopened document file:///tmp/never.py")) {
            try client.didChange(uri: "file:///tmp/never.py", version: 1, text: "")
        }
    }

    @Test func closeIsReportedThroughNotificationHandler() async throws {
        let (client, transport) = try await launchedClient()
        var notifications: [String] = []
        client.onServerNotification = { notifications.append($0.method ?? "?") }

        transport.deliver(.notification("textDocument/publishDiagnostics", params: .object([:])))
        transport.deliver(.notification("window/logMessage", params: .object([:])))

        #expect(notifications == ["textDocument/publishDiagnostics", "window/logMessage"])
    }

    // MARK: - Linger

    @Test func lastCloseSchedulesShutdownAfterLinger() async throws {
        let (client, transport) = try await launchedClient(lingerInterval: 0.08)
        try client.didOpen(uri: "file:///tmp/a.py", languageID: "python", version: 1, text: "")
        try client.didClose(uri: "file:///tmp/a.py")

        // Still alive inside the window.
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(client.state == .running)
        #expect(transport.sent("shutdown").isEmpty)

        // Past the window: shutdown, exit, terminated.
        await waitUntil("shutdown sent") { !transport.sent("shutdown").isEmpty }
        await waitUntil("terminated") { client.state == .terminated }
        #expect(transport.sent("exit").count == 1)
        #expect(transport.isClosed)
    }

    @Test func reopenInsideWindowCancelsLinger() async throws {
        let (client, transport) = try await launchedClient(lingerInterval: 0.08)
        try client.didOpen(uri: "file:///tmp/a.py", languageID: "python", version: 1, text: "")
        try client.didClose(uri: "file:///tmp/a.py")
        try? await Task.sleep(nanoseconds: 30_000_000)
        try client.didOpen(uri: "file:///tmp/b.py", languageID: "python", version: 1, text: "")

        try? await Task.sleep(nanoseconds: 120_000_000)
        #expect(client.state == .running)
        #expect(transport.sent("shutdown").isEmpty)
    }

    // MARK: - Failures

    @Test func crashFailsPendingRequestsAndReportsTermination() async throws {
        let (client, transport) = try await launchedClient()
        var terminationErrors: [Error] = []
        client.onTerminated = { terminationErrors.append($0) }

        let pending = Task { try await client.sendRequest("custom/hang") }
        await waitUntil("request sent") { transport.sent("custom/hang").count == 1 }
        transport.end(with: LSPError.terminated)

        await #expect(throws: LSPError.terminated) { try await pending.value }
        #expect(!terminationErrors.isEmpty)
        if case .failed = client.state {} else {
            Issue.record("expected failed state, got \(client.state)")
        }
    }

    @Test func gracefulEndWithoutShutdownReportsTermination() async throws {
        let (client, transport) = try await launchedClient()
        var didTerminate = false
        client.onTerminated = { _ in didTerminate = true }

        transport.end(with: nil)

        #expect(didTerminate)
        #expect(client.state == .terminated)
    }

    @Test func requestsAfterShutdownAreRejected() async throws {
        let (client, transport) = try await launchedClient()
        try client.didOpen(uri: "file:///tmp/a.py", languageID: "python", version: 1, text: "")
        await client.shutdownAndExit()

        await #expect(throws: LSPError.notRunning) {
            try await client.sendRequest("custom/after")
        }
        #expect(transport.isClosed)
    }
}
