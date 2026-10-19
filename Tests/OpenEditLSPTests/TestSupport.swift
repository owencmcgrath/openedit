import Foundation
import Testing
import OpenEditConfig
@testable import OpenEditLSP

/// Transport that records outbound messages and can auto-answer the
/// handshake, for pool tests that need "a server that starts immediately".
@MainActor
final class ScriptedTransport: ServerTransport {
    var onMessage: ((JSONRPCMessage) -> Void)?
    var onClosed: ((Error?) -> Void)?
    private(set) var sent: [JSONRPCMessage] = []
    private(set) var isClosed = false

    var autoRespondToInitialize = true

    func start() {}
    func send(_ message: JSONRPCMessage) throws {
        sent.append(message)
        if autoRespondToInitialize, message.method == "initialize", let id = message.id {
            onMessage?(.success(id: id, .object(["capabilities": .object([:])])))
        }
    }
    func closeWriteEnd() {}
    func close() {
        isClosed = true
        // ProcessTransport.close always reports closure (EOF/termination);
        // mirror that so the client's shutdown sequence can complete.
        onClosed?(nil)
    }

    func deliver(_ message: JSONRPCMessage) { onMessage?(message) }
    func end(with error: Error?) { onClosed?(error) }

    func sent(_ method: String) -> [JSONRPCMessage] {
        sent.filter { $0.method == method }
    }
}

@MainActor
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 3,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    #expect(condition(), "timed out waiting for: \(description)")
}

/// Polls a file's contents until `condition` holds (integration tests read the
/// test server's JSONL log while the process is still writing to it).
func waitForLog(
    at url: URL,
    timeout: TimeInterval = 5,
    _ condition: (String) -> Bool
) async -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var contents = ""
    while Date() < deadline {
        contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if condition(contents) { return contents }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return contents
}

/// Parses the test server's JSONL log into one dictionary per line.
func parseLog(_ contents: String) -> [[String: Any]] {
    contents.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

/// Locates the `lsp-test-server` executable built alongside the test runner.
/// `OPENEDIT_TEST_LSP_SERVER_PATH` overrides for out-of-tree runs.
enum TestServerBinary {
    static func url() -> URL? {
        if let override = ProcessInfo.processInfo.environment["OPENEDIT_TEST_LSP_SERVER_PATH"] {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        var roots: [URL] = []
        if let argumentZero = CommandLine.arguments.first {
            roots.append(URL(fileURLWithPath: argumentZero).deletingLastPathComponent())
        }
        roots.append(Bundle.main.bundleURL)
        roots.append(Bundle(for: BundleToken.self).bundleURL)
        if let testBundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            roots.append(testBundle.bundleURL)
        }

        for root in roots {
            var candidate: URL? = root
            for _ in 0..<6 {
                guard let directory = candidate else { break }
                let binary = directory.appendingPathComponent("lsp-test-server")
                if FileManager.default.isExecutableFile(atPath: binary.path) {
                    return binary
                }
                candidate = directory.deletingLastPathComponent()
            }
        }
        return nil
    }
}

private final class BundleToken {}

/// One isolated temp directory per test: config file, log file.
struct TestServerFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openedit-lsp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var logURL: URL { directory.appendingPathComponent("server.log") }

    /// Writes the server config file and returns its path (to set in the
    /// `OPENEDIT_TEST_LSP_CONFIG` environment of the spawned process).
    func writeConfig(_ object: [String: Any]) throws -> String {
        var config = object
        config["logPath"] = logURL.path
        let data = try JSONSerialization.data(withJSONObject: config)
        let url = directory.appendingPathComponent("config.json")
        try data.write(to: url)
        return url.path
    }

    func readLog() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Resolved language used by pool/integration tests.
func testLanguage(_ languageID: String, grammar: String, extensions: [String]) -> ResolvedLanguage {
    ResolvedLanguage(
        languageID: languageID,
        extensions: extensions,
        grammar: grammar,
        binaryName: languageID,
        installCommand: nil
    )
}
