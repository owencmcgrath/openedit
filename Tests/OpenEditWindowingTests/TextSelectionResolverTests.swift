import Foundation
import Testing

@testable import OpenEditWindowing

@Suite struct TextSelectionResolverTests {
    private let text = "alpha\nbravo\ncharlie"

    @Test func singleLineSingleColumnIsACaret() {
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 2, column: 3),
                end: TextPosition(line: 2, column: 3)
            ),
            in: text
        )
        #expect(range == NSRange(location: 8, length: 0))
    }

    @Test func caretAtColumnOneIsTheLineStartNotTheWholeLine() {
        // What a bare `file:N` resolves to after makeSelection normalizes the
        // missing column; zero length means a caret, not a highlight.
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 2, column: 1),
                end: TextPosition(line: 2, column: 1)
            ),
            in: text
        )
        #expect(range == NSRange(location: 6, length: 0))
    }

    @Test func explicitSingleLineRangeSelectsTheWholeLine() {
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 2),
                end: TextPosition(line: 2)
            ),
            in: text
        )
        #expect(range == NSRange(location: 6, length: 5))
    }

    @Test func wholeLineRangeExcludesNewlines() {
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 1),
                end: TextPosition(line: 2)
            ),
            in: text
        )
        #expect(range == NSRange(location: 0, length: 11))
    }

    @Test func columnRangeAppliesToBothEndpoints() {
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 1, column: 3),
                end: TextPosition(line: 3, column: 4)
            ),
            in: text
        )
        #expect(range == NSRange(location: 2, length: 13))
    }

    @Test func positionsPastTheEndClamp() {
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 99, column: 99),
                end: TextPosition(line: 99, column: 99)
            ),
            in: text
        )
        #expect(range == NSRange(location: 19, length: 0))
    }

    @Test func trailingNewlineOpensAnEmptyLastLine() {
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 3),
                end: TextPosition(line: 3)
            ),
            in: "one\ntwo\n"
        )
        #expect(range == NSRange(location: 8, length: 0))
    }

    @Test func reversedSelectionIsNormalized() {
        let range = TextSelectionResolver.range(
            for: TextSelection(
                start: TextPosition(line: 3, column: 4),
                end: TextPosition(line: 1, column: 3)
            ),
            in: text
        )
        #expect(range == NSRange(location: 2, length: 13))
    }
}

@Suite struct OpenTextEncodingTests {
    @Test func commonNamesResolve() {
        #expect(OpenTextEncoding.stringEncoding(forName: "UTF-8") == .utf8)
        #expect(OpenTextEncoding.stringEncoding(forName: "latin1") == .isoLatin1)
        #expect(OpenTextEncoding.stringEncoding(forName: "windows-1252") == .windowsCP1252)
        #expect(OpenTextEncoding.stringEncoding(forName: "ISO-8859-2") == .isoLatin2)
    }

    @Test func unknownNameIsNil() {
        #expect(OpenTextEncoding.stringEncoding(forName: "not-a-charset") == nil)
    }
}
