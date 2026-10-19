import Foundation
import Testing
import OpenEditConfig
@testable import OpenEditLSP

/// End-to-end coverage for #6 Checkpoint A: the real `ProcessTransport`
/// speaking to the controlled `lsp-test-server` executable, asserting the
/// exact wire order and payloads from the server's own log.
@Suite @MainActor struct LSPTestServerIntegrationTests {
    private func requireServer() throws -> URL {
        guard let url = TestServerBinary.url() else {
            Issue.record("lsp-test-server executable not found; set OPENEDIT_TEST_LSP_SERVER_PATH or build it")
            throw LSPError.launchFailed("test server missing")
        }
        return url
    }

    private func makeClient(serverURL: URL, configPath: String, lingerInterval: TimeInterval = 0.3) -> LanguageServerClient {
        var environment = ProcessInfo.processInfo.environment
        environment["OPENEDIT_TEST_LSP_CONFIG"] = configPath
        let transport = ProcessTransport(executablePath: serverURL.path, environment: environment)
        return LanguageServerClient(transport: transport, lingerInterval: lingerInterval)
    }

    private func pythonURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/openedit-integration/\(name).py")
    }

    @Test func handshakeAndDocumentLifecycleMatchProtocol() async throws {
        let serverURL = try requireServer()
        let fixture = try TestServerFixture()
        defer { fixture.cleanUp() }
        let configPath = try fixture.writeConfig(["mode": "standard"])

        let client = makeClient(serverURL: serverURL, configPath: configPath)
        defer { Task { await client.shutdownAndExit() } }

        try await client.launch()
        #expect(client.isReady)
        #expect(client.serverCapabilities?["capabilities"]?["textDocumentSync"]?.intValue == 1)

        let uri = pythonURL("a").absoluteString
        try client.didOpen(uri: uri, languageID: "python", version: 1, text: "x = 1\n")
        try client.didChange(uri: uri, version: 2, text: "x = 2\ny = 3\n")
        try client.didClose(uri: uri)

        // Linger will shut the server down; give it time to land in the log.
        _ = await waitForLog(at: fixture.logURL) { $0.contains("\"method\":\"shutdown\"") }
        await client.shutdownAndExit()

        let log = parseLog(fixture.readLog())
        let inboundMethods = log.filter { $0["dir"] as? String == "in" }.compactMap { $0["method"] as? String }
        // The exit notification races process teardown (its arrival is not
        // guaranteed to land in the log before the server dies), so the
        // asserted contract is the order through didClose, plus shutdown.
        #expect(Array(inboundMethods.prefix(5)) == [
            "initialize", "initialized",
            "textDocument/didOpen", "textDocument/didChange", "textDocument/didClose",
        ])
        #expect(inboundMethods.contains("shutdown"))

        let open = log.first { $0["method"] as? String == "textDocument/didOpen" }?["params"] as? [String: Any]
        let openDocument = open?["textDocument"] as? [String: Any]
        #expect(openDocument?["uri"] as? String == uri)
        #expect(openDocument?["languageId"] as? String == "python")
        #expect(openDocument?["version"] as? Int == 1)
        #expect(openDocument?["text"] as? String == "x = 1\n")

        let change = log.first { $0["method"] as? String == "textDocument/didChange" }?["params"] as? [String: Any]
        let changeDocument = change?["textDocument"] as? [String: Any]
        let changes = change?["contentChanges"] as? [[String: Any]]
        #expect(changeDocument?["version"] as? Int == 2)
        #expect(changes?.count == 1)
        #expect(changes?.first?["text"] as? String == "x = 2\ny = 3\n")

        // initialize carried a null rootUri (#6 decision). (`as?` unwraps the
        // dictionary subscript's optional; bare `is NSNull` would test the
        // Optional wrapper, not the value.)
        let initialize = log.first { $0["method"] as? String == "initialize" }?["params"] as? [String: Any]
        #expect((initialize?["rootUri"] as? NSNull) != nil)
    }

    @Test func diagnosticsNotificationReachesTheClient() async throws {
        let serverURL = try requireServer()
        let fixture = try TestServerFixture()
        defer { fixture.cleanUp() }
        let configPath = try fixture.writeConfig([
            "mode": "standard",
            "diagnostics": [
                "message": "unused variable 'x'",
                "severity": 2,
                "startLine": 0, "startCharacter": 0, "endLine": 0, "endCharacter": 1,
            ],
        ])

        let client = makeClient(serverURL: serverURL, configPath: configPath)
        defer { Task { await client.shutdownAndExit() } }
        var received: [JSONValue] = []
        client.onServerNotification = { message in
            if message.method == "textDocument/publishDiagnostics" {
                received.append(message.params ?? .null)
            }
        }

        try await client.launch()
        try client.didOpen(uri: pythonURL("diag").absoluteString, languageID: "python", version: 1, text: "x = 1\n")
        await waitUntil("publishDiagnostics received") { !received.isEmpty }

        let diagnostics = received.first?["diagnostics"]?.arrayValue ?? []
        if diagnostics.isEmpty {
            Issue.record("publishDiagnostics params were: \(String(describing: received.first))")
        }
        // The server echoes the opened document's URI and version.
        #expect(received.first?["uri"]?.stringValue == pythonURL("diag").absoluteString)
        #expect(received.first?["version"]?.intValue == 1)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?["message"]?.stringValue == "unused variable 'x'")
        #expect(diagnostics.first?["severity"]?.intValue == 2)
    }

    @Test func crashMidSessionIsSurvived() async throws {
        let serverURL = try requireServer()
        let fixture = try TestServerFixture()
        defer { fixture.cleanUp() }
        let configPath = try fixture.writeConfig(["mode": "crash"])

        let client = makeClient(serverURL: serverURL, configPath: configPath)
        var terminated = false
        client.onTerminated = { _ in terminated = true }

        try await client.launch()
        // The crash happens on didOpen; the client must not throw or hang.
        try? client.didOpen(uri: pythonURL("crash").absoluteString, languageID: "python", version: 1, text: "")

        await waitUntil("termination reported") { terminated }
        if case .failed = client.state {} else if client.state == .terminated {} else {
            Issue.record("expected failed/terminated state, got \(client.state)")
        }
    }

    @Test func malformedGarbageDoesNotHangTheHandshake() async throws {
        let serverURL = try requireServer()
        let fixture = try TestServerFixture()
        defer { fixture.cleanUp() }
        let configPath = try fixture.writeConfig(["mode": "malformed"])

        let client = makeClient(serverURL: serverURL, configPath: configPath)
        var terminated = false
        client.onTerminated = { _ in terminated = true }

        // The server writes garbage before the initialize response; the
        // decoder cannot resynchronize and the client fails the connection
        // rather than crashing or hanging forever.
        do {
            try await client.launch()
            Issue.record("handshake unexpectedly succeeded despite garbage framing")
        } catch {
            // expected
        }
        await waitUntil("client ended after malformed framing") {
            terminated || client.state == .terminated || !client.isReady
        }
        #expect(!client.isReady)
    }

    @Test func missingExecutableFailsCleanly() async throws {
        let transport = ProcessTransport(executablePath: "/nonexistent/definitely-not-a-server")
        let client = LanguageServerClient(transport: transport, lingerInterval: 0.05)

        do {
            try await client.launch()
            Issue.record("launch unexpectedly succeeded")
        } catch {
            // expected: launchFailed
        }
    }
}
