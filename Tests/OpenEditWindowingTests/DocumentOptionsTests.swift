import Foundation
import Testing

@testable import OpenEdit
import OpenEditWindowing

@Suite @MainActor struct DocumentOptionsTests {
    private func temporaryFile(contents: String, encoding: String.Encoding = .utf8) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openedit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.txt")
        try contents.data(using: encoding)!.write(to: url)
        return url
    }

    @Test func explicitLFNormalizesCRLFOnLoadAndSave() throws {
        let url = try temporaryFile(contents: "a\r\nb\r\n")
        var options = OpenDocumentOptions()
        options.lineEnding = .lf
        TextDocument.pendingOpenOptions[url.standardizedFileURL] = options

        let document = try TextDocument(fileAt: url)
        #expect(document.text == "a\nb\n")
        let saved = String(data: try document.data(ofType: TextDocument.fileTypeIdentifier), encoding: .utf8)
        #expect(saved == "a\nb\n")
    }

    @Test func explicitCRLFWritesCRLF() throws {
        let url = try temporaryFile(contents: "a\nb\n")
        var options = OpenDocumentOptions()
        options.lineEnding = .crlf
        TextDocument.pendingOpenOptions[url.standardizedFileURL] = options

        let document = try TextDocument(fileAt: url)
        #expect(document.text == "a\nb\n")
        let saved = String(data: try document.data(ofType: TextDocument.fileTypeIdentifier), encoding: .utf8)
        #expect(saved == "a\r\nb\r\n")
    }

    @Test func requestedEncodingDecodesAndWrites() throws {
        let url = try temporaryFile(contents: "café", encoding: .isoLatin1)
        var options = OpenDocumentOptions()
        options.encoding = "ISO-8859-1"
        TextDocument.pendingOpenOptions[url.standardizedFileURL] = options

        let document = try TextDocument(fileAt: url)
        #expect(document.text == "café")
        let saved = try document.data(ofType: TextDocument.fileTypeIdentifier)
        #expect(saved == "café".data(using: .isoLatin1))
    }

    @Test func perDocumentConfigDefinesTheLanguage() throws {
        let url = try temporaryFile(contents: "x")
        let config = url.deletingLastPathComponent().appendingPathComponent("languages.toml")
        try """
            [[language]]
            extensions = ["txt"]
            languageId = "custom"
            grammar = "json"
            """.write(to: config, atomically: true, encoding: .utf8)

        var options = OpenDocumentOptions()
        options.configPath = config.path
        let language = DocumentLanguageMapping.resolvedLanguage(for: url, options: options)
        #expect(language?.languageID == "custom")
        #expect(language?.grammar == "json")
    }

    @Test func highlightingAndAutodetectionCanBeDisabledPerDocument() {
        let url = URL(fileURLWithPath: "/tmp/sample.py")
        var options = OpenDocumentOptions()
        options.highlighting = false
        options.autodetectServers = false

        let language = DocumentLanguageMapping.resolvedLanguage(for: url, options: options)
        #expect(language?.languageID == "python")
        #expect(language?.grammar == nil)
        #expect(language?.binaryAlternatives.isEmpty == true)
    }

    @Test func forcedLanguageAndServerOverrideWin() {
        let url = URL(fileURLWithPath: "/tmp/sample.unknown")
        var options = OpenDocumentOptions()
        options.forcedLanguage = "python"
        options.lspServerOverrides = ["python": "/opt/bin/pylsp"]

        let language = DocumentLanguageMapping.resolvedLanguage(for: url, options: options)
        #expect(language?.languageID == "python")
        #expect(language?.grammar == "python")
        #expect(language?.lspPath == "/opt/bin/pylsp")
        #expect(language?.binaryName == "pylsp")
    }

    @Test func reopenStackIsMRUDedupedAndSkipsMissingFiles() throws {
        let suiteName = "openedit-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ReopenStore(defaults: defaults)

        let file = try temporaryFile(contents: "x")
        let missing = file.deletingLastPathComponent().appendingPathComponent("gone.txt")
        store.record(fileURL: file)
        store.record(fileURL: missing)
        store.record(fileURL: file)

        #expect(store.lastClosedPaths == [missing.path, file.path])
        // The missing path is dropped and the search continues to the file.
        #expect(store.popLastClosed() == file.standardizedFileURL)
        #expect(store.popLastClosed() == nil)
        #expect(store.lastClosedPaths.isEmpty)
    }

    @Test func waitStatusFileIsJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openedit-wait-\(UUID().uuidString).json")
        WaitStatusWriter.write(state: "saved", path: "/tmp/a b.txt", to: url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        #expect(object == ["state": "saved", "path": "/tmp/a b.txt"])
    }
}
