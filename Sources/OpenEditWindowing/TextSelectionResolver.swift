import Foundation

/// Converts the CLI's 1-based line/column grammar into an AppKit `NSRange`
/// against the document's live text (ARCHITECTURE.md 5.1). Kept Foundation-only
/// and pure so the clamping rules are unit-testable without a window server.
public enum TextSelectionResolver {
    /// Resolve a selection. A nil column means the start of the line for a
    /// start endpoint and the end of the line (excluding its newline) for an
    /// end endpoint. Lines and columns past the end clamp to the last
    /// line/character; columns count UTF-16 code units.
    public static func range(for selection: TextSelection, in text: String) -> NSRange {
        let string = text as NSString
        let startLine = clampedLine(selection.start.line, in: string)
        let endLine = clampedLine(selection.end.line, in: string)

        let start = offset(
            line: startLine,
            column: selection.start.column,
            in: string,
            atEnd: false
        )
        let end = offset(
            line: endLine,
            column: selection.end.column,
            in: string,
            atEnd: true
        )

        let location = min(start, end)
        return NSRange(location: location, length: max(start, end) - location)
    }

    private static func offset(
        line: Int,
        column: Int?,
        in string: NSString,
        atEnd: Bool
    ) -> Int {
        let lineRange = string.lineRange(for: NSRange(location: lineStart(line, in: string), length: 0))
        let contentEnd = lineContentEnd(lineRange, in: string)
        guard let column else {
            return atEnd ? contentEnd : lineRange.location
        }
        let requested = lineRange.location + max(0, column - 1)
        return min(requested, contentEnd)
    }

    private static func clampedLine(_ line: Int, in string: NSString) -> Int {
        min(max(1, line), lineCount(in: string))
    }

    private static func lineCount(in string: NSString) -> Int {
        guard string.length > 0 else { return 1 }
        var count = 1
        var index = 0
        while index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let next = NSMaxRange(lineRange)
            if next < string.length {
                count += 1
            } else if isNewline(string.character(at: string.length - 1)) {
                // A trailing newline opens one final, empty line.
                count += 1
            }
            guard next > index else { break }
            index = next
        }
        return count
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }

    private static func lineStart(_ line: Int, in string: NSString) -> Int {
        guard line > 1, string.length > 0 else { return 0 }
        var start = 0
        for _ in 1..<line {
            let range = string.lineRange(for: NSRange(location: start, length: 0))
            let next = NSMaxRange(range)
            guard next > start, next <= string.length else { return start }
            start = next
        }
        return start
    }

    private static func lineContentEnd(_ lineRange: NSRange, in string: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = string.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return end
    }
}
