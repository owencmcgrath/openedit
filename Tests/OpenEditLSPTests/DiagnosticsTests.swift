import Foundation
import Testing
@testable import OpenEditLSP

@Suite struct LSPPositionTests {
    @Test func offsetToPositionCountsUTF16Units() {
        let text = "a = \"héllo\"\nnext\n" as NSString
        // `a = "héllo"` is 11 UTF-16 units (é is one unit), so the newline is
        // at unit 11.
        let position = LSPPosition(utf16Offset: 11, in: text)
        #expect(position.line == 0)
        #expect(position.character == 11)
    }

    @Test func offsetToPositionCountsSurrogatePairsAsTwoUnits() {
        let text = "x = \"🚀\"\ny\n" as NSString
        // The emoji is one grapheme but two UTF-16 code units; the closing
        // quote sits at unit 7.
        let position = LSPPosition(utf16Offset: 7, in: text)
        #expect(position.line == 0)
        #expect(position.character == 7)
    }

    @Test func positionToOffsetValidatesAndClamps() {
        let text = "ab\ncde\n" as NSString
        #expect(LSPPosition(line: 0, character: 1).utf16Offset(in: text) == 1)
        #expect(LSPPosition(line: 1, character: 0).utf16Offset(in: text) == 3)
        #expect(LSPPosition(line: 1, character: 2).utf16Offset(in: text) == 5)
        // Character past the line clamps to the line end.
        #expect(LSPPosition(line: 1, character: 99).utf16Offset(in: text) == 6)
        // A line past the document is invalid.
        #expect(LSPPosition(line: 5, character: 0).utf16Offset(in: text) == nil)
    }

    @Test func rangeMapsMultilineAndRejectsInvalid() {
        let text = "abc\ndef\n" as NSString
        let valid = LSPRange(
            start: LSPPosition(line: 0, character: 1),
            end: LSPPosition(line: 1, character: 1)
        )
        #expect(valid.nsRange(in: text) == NSRange(location: 1, length: 4))

        let inverted = LSPRange(
            start: LSPPosition(line: 1, character: 2),
            end: LSPPosition(line: 0, character: 0)
        )
        #expect(inverted.nsRange(in: text) == nil)

        let offDocument = LSPRange(
            start: LSPPosition(line: 9, character: 0),
            end: LSPPosition(line: 9, character: 1)
        )
        #expect(offDocument.nsRange(in: text) == nil)
    }
}

@Suite struct DiagnosticParsingTests {
    private func diagnosticJSON(severity: JSONValue?, message: String = "boom") -> JSONValue {
        var object: [String: JSONValue] = [
            "range": .object([
                "start": .object(["line": .number(0), "character": .number(0)]),
                "end": .object(["line": .number(0), "character": .number(3)]),
            ]),
            "message": .string(message),
        ]
        if let severity { object["severity"] = severity }
        return .object(object)
    }

    @Test func parsesSeverityAndFields() {
        let diagnostic = Diagnostic.parse(diagnosticJSON(severity: .number(1), message: "syntax error"))
        #expect(diagnostic?.severity == .error)
        #expect(diagnostic?.message == "syntax error")
        #expect(diagnostic?.range.start == LSPPosition(line: 0, character: 0))
        #expect(diagnostic?.range.end == LSPPosition(line: 0, character: 3))
    }

    @Test func unknownSeverityFallsBackToInformation() {
        #expect(Diagnostic.parse(diagnosticJSON(severity: .number(99)))?.severity == .information)
        #expect(Diagnostic.parse(diagnosticJSON(severity: nil))?.severity == .information)
    }

    @Test func malformedDiagnosticIsSkipped() {
        #expect(Diagnostic.parse(.object(["message": .string("no range")])) == nil)
        #expect(Diagnostic.parse(.object([
            "range": .object([
                "start": .object(["line": .number(0), "character": .number(0)]),
                "end": .object(["line": .number(0), "character": .number(1)]),
            ]),
        ])) == nil) // no message
    }

    @Test func parsesPublishEnvelope() {
        let params = JSONValue.object([
            "uri": .string("file:///tmp/a.py"),
            "version": .number(3),
            "diagnostics": .array([
                diagnosticJSON(severity: .number(2), message: "unused"),
                .object(["bogus": .string("x")]), // skipped
            ]),
        ])
        let publish = DiagnosticsPublish.parse(params: params)
        #expect(publish?.uri == "file:///tmp/a.py")
        #expect(publish?.version == 3)
        #expect(publish?.diagnostics.count == 1)
        #expect(publish?.diagnostics.first?.severity == .warning)
    }

    @Test func missingURIMeansNoPublish() {
        #expect(DiagnosticsPublish.parse(params: .object(["diagnostics": .array([])])) == nil)
    }
}

@Suite struct DocumentDiagnosticsTests {
    private func publish(
        uri: String = "file:///tmp/a.py",
        version: Int?,
        ranges: [(Int, Int)] = [(0, 1)]
    ) -> DiagnosticsPublish {
        let diagnostics = ranges.map { start, end in
            Diagnostic(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: start),
                    end: LSPPosition(line: 0, character: end)
                ),
                severity: .error,
                message: "d\(start)"
            )
        }
        return DiagnosticsPublish(uri: uri, version: version, diagnostics: diagnostics)
    }

    @Test func acceptsMatchingVersion() {
        var store = DocumentDiagnostics()
        let accepted = store.accept(publish(version: 2), currentVersion: 2)
        #expect(accepted)
        #expect(store.diagnostics.count == 1)
        #expect(store.acceptedVersion == 2)
    }

    @Test func rejectsStaleVersion() {
        var store = DocumentDiagnostics()
        let rejected = !store.accept(publish(version: 1), currentVersion: 2)
        #expect(rejected)
        #expect(store.diagnostics.isEmpty)
    }

    @Test func acceptsVersionlessPublish() {
        var store = DocumentDiagnostics()
        let accepted = store.accept(publish(version: nil), currentVersion: 7)
        #expect(accepted)
    }

    @Test func invalidateClearsUntilRepublish() {
        var store = DocumentDiagnostics()
        _ = store.accept(publish(version: 1), currentVersion: 1)
        store.invalidate()
        #expect(store.diagnostics.isEmpty)
        #expect(store.renderable(in: "abc" as NSString).isEmpty)
    }

    @Test func renderableValidatesAndSorts() {
        var store = DocumentDiagnostics()
        // Second range starts later but is listed first; the first is off the
        // document and must be dropped.
        let publish = DiagnosticsPublish(uri: "u", version: nil, diagnostics: [
            Diagnostic(
                range: LSPRange(
                    start: LSPPosition(line: 9, character: 0),
                    end: LSPPosition(line: 9, character: 1)
                ),
                severity: .error, message: "off-document"
            ),
            Diagnostic(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 2),
                    end: LSPPosition(line: 0, character: 3)
                ),
                severity: .warning, message: "later"
            ),
            Diagnostic(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 1)
                ),
                severity: .error, message: "earlier"
            ),
        ])
        _ = store.accept(publish, currentVersion: 1)

        let renderable = store.renderable(in: "abc" as NSString)
        #expect(renderable.map(\.message) == ["earlier", "later"])
        #expect(renderable.first?.range == NSRange(location: 0, length: 1))
        #expect(renderable.last?.range == NSRange(location: 2, length: 1))
    }

    @Test func diagnosticAtOffsetFindsContainingAndPointRanges() {
        var store = DocumentDiagnostics()
        let publish = DiagnosticsPublish(uri: "u", version: nil, diagnostics: [
            Diagnostic(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 3)
                ),
                severity: .error, message: "span"
            ),
            Diagnostic(
                range: LSPRange(
                    start: LSPPosition(line: 1, character: 0),
                    end: LSPPosition(line: 1, character: 0)
                ),
                severity: .hint, message: "point"
            ),
        ])
        _ = store.accept(publish, currentVersion: 1)
        let text = "abc\ndef\n" as NSString

        #expect(store.diagnostic(atUTF16Offset: 1, in: text)?.message == "span")
        #expect(store.diagnostic(atUTF16Offset: 3, in: text)?.message == nil) // past the span
        #expect(store.diagnostic(atUTF16Offset: 4, in: text)?.message == "point")
    }
}

@Suite struct LSPHoverTests {
    @Test func stringContents() {
        #expect(LSPHover.plainText(from: .object(["contents": .string("hi")])) == "hi")
    }

    @Test func markupContentUsesValue() {
        let result = JSONValue.object([
            "contents": .object(["kind": .string("markdown"), "value": .string("**bold**")]),
        ])
        #expect(LSPHover.plainText(from: result) == "**bold**")
    }

    @Test func arrayContentsJoin() {
        let result = JSONValue.object([
            "contents": .array([
                .string("first"),
                .object(["kind": .string("plaintext"), "value": .string("second")]),
            ]),
        ])
        #expect(LSPHover.plainText(from: result) == "first\n\nsecond")
    }

    @Test func nullOrEmptyIsNil() {
        #expect(LSPHover.plainText(from: nil) == nil)
        #expect(LSPHover.plainText(from: .object(["contents": .string("")])) == nil)
        #expect(LSPHover.plainText(from: .object([:] )) == nil)
    }
}
