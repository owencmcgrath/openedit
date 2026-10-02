import Foundation

/// LSP text position: zero-based `line`, and `character` measured in UTF-16
/// code units (the LSP spec's unit). OpenEdit's `NSTextStorage`/`NSString` are
/// UTF-16 too, so this is a direct mapping with no transcoding — only
/// line-offset bookkeeping.
public struct LSPPosition: Equatable, Sendable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    /// The position at a UTF-16 offset in `text`.
    public init(utf16Offset offset: Int, in text: NSString) {
        let clamped = max(0, min(offset, text.length))
        var line = 0
        var lineStart = 0
        var index = 0
        while index < clamped {
            if text.character(at: index) == 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        self.line = line
        self.character = clamped - lineStart
    }

    /// UTF-16 offset for this position in `text`, validating bounds: the line
    /// must exist, and `character` is clamped to the line's length (a common
    /// server quirk for end-of-line positions). Returns nil for a line past
    /// the document.
    public func utf16Offset(in text: NSString) -> Int? {
        guard line >= 0, character >= 0 else { return nil }
        let length = text.length
        var currentLine = 0
        var index = 0
        while currentLine < line {
            guard index < length else { return nil } // line past end of document
            if text.character(at: index) == 0x0A {
                currentLine += 1
            }
            index += 1
        }
        guard currentLine == line else { return nil }

        // Find this line's length (exclusive of the newline).
        var lineEnd = index
        while lineEnd < length, text.character(at: lineEnd) != 0x0A {
            lineEnd += 1
        }
        let lineLength = lineEnd - index
        return index + min(character, lineLength)
    }
}

/// LSP text range.
public struct LSPRange: Equatable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    /// An `NSRange` (UTF-16) for this range in `text`, or nil when it cannot be
    /// validated (a line past the document, or a start after the end).
    public func nsRange(in text: NSString) -> NSRange? {
        guard let startOffset = start.utf16Offset(in: text),
              let endOffset = end.utf16Offset(in: text),
              endOffset >= startOffset
        else { return nil }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }
}
