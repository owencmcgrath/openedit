import Foundation
import Testing

@testable import OpenEditLog

@Suite(.serialized) struct OpenEditLogTests {
    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openedit-log-tests-\(UUID().uuidString).log")
    }

    @Test func fileSinkReceivesLinesAtOrAboveTheLevel() {
        let url = temporaryLogURL()
        let log = OpenEditLog.shared
        log.configure(level: .warning, fileURL: url)
        log.debug(category: "test", "filtered out")
        log.warning(category: "test", "kept warning")
        log.error(category: "test", "kept error")
        log.removeFileSink()
        defer { log.configure(level: .info, fileURL: nil) }

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: url)
        #expect(!contents.contains("filtered out"))
        #expect(contents.contains("[WARNING] [test] kept warning"))
        #expect(contents.contains("[ERROR] [test] kept error"))
    }

    @Test func appendOnlySinkKeepsEarlierLines() {
        let url = temporaryLogURL()
        try? "earlier\n".write(to: url, atomically: true, encoding: .utf8)

        let log = OpenEditLog.shared
        log.configure(level: .info, fileURL: url)
        log.info(category: "test", "kept info")
        log.removeFileSink()
        defer { log.configure(level: .info, fileURL: nil) }

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: url)
        #expect(contents.contains("earlier"))
        #expect(contents.contains("kept info"))
    }

    @Test func levelNamesRoundTrip() {
        for level in OpenEditLogLevel.allCases {
            #expect(OpenEditLogLevel(name: level.name) == level)
        }
        #expect(OpenEditLogLevel(name: "err") == .error)
        #expect(OpenEditLogLevel(name: "warn") == .warning)
        #expect(OpenEditLogLevel(name: "nonsense") == nil)
    }
}
