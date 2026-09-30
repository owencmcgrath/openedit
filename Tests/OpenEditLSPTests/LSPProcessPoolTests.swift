import Foundation
import Testing
import OpenEditConfig
@testable import OpenEditLSP

@Suite @MainActor struct LSPProcessPoolTests {
    private func pythonURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/pooltests/\(name).py")
    }

    private func jsonURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/pooltests/\(name).json")
    }

    /// Pool whose clients run on `ScriptedTransport`s, with one transport per
    /// spawn so tests can observe spawn count and payloads.
    private func makePool(
        lingerInterval: TimeInterval = 0.05
    ) -> (pool: LSPProcessPool, transports: () -> [ScriptedTransport]) {
        var created: [ScriptedTransport] = []
        let pool = LSPProcessPool(
            languageResolver: { url in
                switch url?.pathExtension {
                case "py": return testLanguage("python", grammar: "python", extensions: ["py"])
                case "json": return testLanguage("json", grammar: "json", extensions: ["json"])
                default: return nil
                }
            },
            clientFactory: { _ in
                let transport = ScriptedTransport()
                created.append(transport)
                return LanguageServerClient(transport: transport, lingerInterval: lingerInterval)
            }
        )
        return (pool, { created })
    }

    private func available(_ executable: String = "/usr/local/bin/fake") -> LanguageServerAvailability {
        .available(executablePath: executable)
    }

    @Test func oneProcessSharedBySameLanguageDocuments() async {
        let (pool, transports) = makePool()
        pool.documentOpened(fileURL: pythonURL("a"), initialText: "a = 1\n", availability: available())
        pool.documentOpened(fileURL: pythonURL("b"), initialText: "b = 2\n", availability: available())

        await waitUntil("both didOpen sent") {
            let all = transports()
            return all.count == 1 && all[0].sent("textDocument/didOpen").count == 2
        }
        #expect(transports().count == 1, "same language must share one process")
        #expect(transports()[0].sent("initialize").count == 1)
    }

    @Test func separateLanguagesGetSeparateProcesses() async {
        let (pool, transports) = makePool()
        pool.documentOpened(fileURL: pythonURL("a"), initialText: "", availability: available("/usr/local/bin/pylsp"))
        pool.documentOpened(fileURL: jsonURL("a"), initialText: "", availability: available("/usr/local/bin/vscode-json"))

        await waitUntil("two processes") {
            let all = transports()
            return all.count == 2
                && all.filter { $0.sent("textDocument/didOpen").count == 1 }.count == 2
        }
        #expect(transports().count == 2)
    }

    @Test func missingAndHighlightingOnlyAvailabilityNeverSpawn() async {
        let (pool, transports) = makePool()
        pool.documentOpened(fileURL: pythonURL("a"), initialText: "", availability: .missing)
        pool.documentOpened(fileURL: jsonURL("a"), initialText: "", availability: .highlightingOnly)

        // Give any accidental spawn a chance to happen, then assert none did.
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(transports().isEmpty)
    }

    @Test func editDuringHandshakeIsBufferedAndFlushedAsLatestText() async {
        var transportsList: [ScriptedTransport] = []
        // Transport handshake is manual here: the edit must land mid-handshake.
        let poolManual = LSPProcessPool(
            languageResolver: { _ in testLanguage("python", grammar: "python", extensions: ["py"]) },
            clientFactory: { _ in
                let transport = ScriptedTransport()
                transport.autoRespondToInitialize = false
                transportsList.append(transport)
                return LanguageServerClient(transport: transport, lingerInterval: 1)
            }
        )

        poolManual.documentOpened(fileURL: pythonURL("a"), initialText: "one = 1\n", availability: available())
        await waitUntil("initialize sent") { transportsList.first?.sent("initialize").count == 1 }
        // Edit lands before the server is ready.
        poolManual.documentEdited(fileURL: pythonURL("a"), newText: "two = 2\n")

        // Complete the handshake.
        let initialize = transportsList[0].sent("initialize")[0]
        transportsList[0].deliver(.success(id: initialize.id!, .object(["capabilities": .object([:])])))

        await waitUntil("didOpen sent") { transportsList.first?.sent("textDocument/didOpen").count == 1 }
        let open = transportsList[0].sent("textDocument/didOpen")[0]
        #expect(open.params?["textDocument"]?["text"]?.stringValue == "two = 2\n")
        // Version advanced past the initial 1 because the buffered edit bumped
        // it before the flush.
        #expect(open.params?["textDocument"]?["version"]?.intValue == 2)
    }

    @Test func versionIncrementsPerEdit() async {
        let (pool, transports) = makePool()
        pool.documentOpened(fileURL: pythonURL("a"), initialText: "a = 1\n", availability: available())
        await waitUntil("didOpen sent") { transports().first?.sent("textDocument/didOpen").count == 1 }

        pool.documentEdited(fileURL: pythonURL("a"), newText: "a = 2\n")
        pool.documentEdited(fileURL: pythonURL("a"), newText: "a = 3\n")

        let changes = transports()[0].sent("textDocument/didChange")
        #expect(changes.count == 2)
        #expect(changes[0].params?["textDocument"]?["version"]?.intValue == 2)
        #expect(changes[1].params?["textDocument"]?["version"]?.intValue == 3)
        #expect(changes[1].params?["contentChanges"]?.arrayValue?[0]["text"]?.stringValue == "a = 3\n")
    }

    @Test func closeStartsLingerAndShutsDownAfterInterval() async {
        let (pool, transports) = makePool(lingerInterval: 0.08)
        pool.documentOpened(fileURL: pythonURL("a"), initialText: "", availability: available())
        await waitUntil("didOpen sent") { transports().first?.sent("textDocument/didOpen").count == 1 }

        pool.documentClosed(fileURL: pythonURL("a"))
        await waitUntil("shutdown sent") { !(transports().first?.sent("shutdown").isEmpty ?? true) }
    }

    @Test func reopenInsideLingerWindowCancelsShutdown() async {
        let (pool, transports) = makePool(lingerInterval: 0.2)
        pool.documentOpened(fileURL: pythonURL("a"), initialText: "", availability: available())
        await waitUntil("didOpen sent") { transports().first?.sent("textDocument/didOpen").count == 1 }
        pool.documentClosed(fileURL: pythonURL("a"))
        try? await Task.sleep(nanoseconds: 60_000_000)
        pool.documentOpened(fileURL: pythonURL("b"), initialText: "", availability: available())

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(transports()[0].sent("shutdown").isEmpty)
        #expect(transports().count == 1, "reopen must reuse the lingered process")
    }

    @Test func editsForUnknownDocumentAreNoOps() async {
        let (pool, transports) = makePool()
        pool.documentEdited(fileURL: pythonURL("never-opened"), newText: "x")
        pool.documentClosed(fileURL: pythonURL("never-opened"))
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(transports().isEmpty)
    }

    @Test func crashedServerIsDroppedAndNextOpenRespawns() async {
        let (pool, transports) = makePool()
        pool.documentOpened(fileURL: pythonURL("a"), initialText: "", availability: available())
        await waitUntil("didOpen sent") { transports().first?.sent("textDocument/didOpen").count == 1 }

        transports()[0].end(with: LSPError.terminated)

        pool.documentOpened(fileURL: pythonURL("b"), initialText: "", availability: available())
        await waitUntil("respawn") {
            let all = transports()
            return all.count == 2 && all[1].sent("textDocument/didOpen").count == 1
        }
    }
}
