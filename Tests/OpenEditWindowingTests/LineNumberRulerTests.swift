import AppKit
import Testing

@testable import OpenEdit
@testable import OpenEditWindowing

/// Regression tests for #37: the gutter's cached line starts were computed at
/// `LineNumberRulerView.init` while the text view was still empty, and a
/// programmatic `NSTextView.string =` replacement posts no
/// `NSText.didChangeNotification`, so every line numbered `1` until the first
/// keystroke recomputed the cache.
@Suite @MainActor struct LineNumberRulerTests {

    @Test func gutterNumbersSequentiallyRightAfterOpen() throws {
        let lineCount = 150 // crosses a power of ten, so the width asserts too
        let text = Self.text(lineCount: lineCount)
        let document = try Self.document(withText: text)
        let ruler = try Self.ruler(of: DocumentWindowController(document: document))

        #expect(ruler.lineNumber(forCharacterIndex: 0) == 1)
        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(1, in: text)) == 2)
        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(lineCount - 1, in: text)) == lineCount)
        #expect(abs(ruler.ruleThickness - Self.expectedThickness(lineCount: lineCount, font: Self.editorFont)) < 0.5)
    }

    @Test func gutterRecomputesAfterWatcherReload() throws {
        let reloadedLineCount = 150
        let reloadedText = Self.text(lineCount: reloadedLineCount)
        let document = try Self.document(withText: Self.text(lineCount: 3))
        let controller = DocumentWindowController(document: document)
        let ruler = try Self.ruler(of: controller)

        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(2, in: Self.text(lineCount: 3))) == 3)

        // The disk-reload path (TextDocument.applyText → controller.applyText)
        // replaces the text programmatically, exactly like the initial load.
        controller.applyText(reloadedText)

        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(reloadedLineCount - 1, in: reloadedText)) == reloadedLineCount)
        #expect(abs(ruler.ruleThickness - Self.expectedThickness(lineCount: reloadedLineCount, font: Self.editorFont)) < 0.5)
    }

    @Test func gutterStaysCorrectAfterUserEdit() throws {
        let text = Self.text(lineCount: 3)
        let document = try Self.document(withText: text)
        let controller = DocumentWindowController(document: document)
        let scrollView = try Self.scrollView(of: controller)
        let textView = try #require(scrollView.documentView as? NSTextView)
        let ruler = try Self.ruler(of: controller)

        // A user keystroke (typed over nothing at the insertion point) inserts
        // a leading character and a newline: the document gains a line, and
        // every cached start shifts by two.
        textView.insertText("x\n")

        let editedText = textView.string
        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(3, in: editedText)) == 4)
    }

    // MARK: - Helpers

    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func text(lineCount: Int) -> String {
        (0..<lineCount).map { "line \($0)" }.joined(separator: "\n")
    }

    /// An in-memory document: no file URL, so no watcher or language server
    /// flow, and an inactive highlighter — only the windowing shell runs.
    static func document(withText text: String) throws -> TextDocument {
        let document = TextDocument()
        try document.read(from: Data(text.utf8), ofType: TextDocument.fileTypeIdentifier)
        return document
    }

    static func scrollView(of controller: DocumentWindowController) throws -> NSScrollView {
        try #require(controller.window?.contentView as? NSScrollView)
    }

    static func ruler(of controller: DocumentWindowController) throws -> LineNumberRulerView {
        try #require(scrollView(of: controller).verticalRulerView as? LineNumberRulerView)
    }

    /// Character index where the 0-based line `n` begins.
    static func startOfLine(_ n: Int, in text: String) -> Int {
        let string = text as NSString
        var location = 0
        for _ in 0..<n {
            location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
        }
        return location
    }

    /// `LineNumberRulerView.updateThickness()`'s formula: a sample of `8`s as
    /// wide as the widest line count, plus the 6pt padding on both sides.
    static func expectedThickness(lineCount: Int, font: NSFont) -> CGFloat {
        let digits = max(2, String(lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + 6 * 2
    }
}
