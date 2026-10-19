import AppKit
import Testing

@testable import OpenEdit

/// Regression tests for #37: the gutter's cached line starts were computed at
/// `LineNumberRulerView.init` while the text view was still empty, and a
/// programmatic `NSTextView.string =` replacement posts no
/// `NSText.didChangeNotification`, so every line numbered `1` until the first
/// keystroke recomputed the cache. The active-line tests pin #47's review
/// behavior: the selection's lines draw their number in the active color.
@Suite @MainActor struct LineNumberRulerTests {

    @Test func gutterNumbersSequentiallyRightAfterOpen() throws {
        let lineCount = 150 // crosses a power of ten, so the width asserts too
        let text = Self.text(lineCount: lineCount)
        let document = try Self.document(withText: text)
        let ruler = try Self.ruler(of: DocumentWindowController(document: document))

        #expect(ruler.lineNumber(forCharacterIndex: 0) == 1)
        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(1, in: text)) == 2)
        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(lineCount - 1, in: text)) == lineCount)

        // Width as an observable delta: the 150-line gutter is exactly one
        // digit wider than a 3-line one (both thicknesses come out of
        // `updateThickness()`, so ±1 covers its ceil rounding). A stale cache
        // would leave the two widths equal and fail this.
        let baseline = try Self.ruler(of: DocumentWindowController(document: try Self.document(withText: Self.text(lineCount: 3))))
        #expect(abs(ruler.ruleThickness - baseline.ruleThickness - Self.digitAdvance) < 1)
    }

    @Test func gutterRecomputesAfterWatcherReload() throws {
        let reloadedLineCount = 150
        let reloadedText = Self.text(lineCount: reloadedLineCount)
        let document = try Self.document(withText: Self.text(lineCount: 3))
        let controller = DocumentWindowController(document: document)
        let ruler = try Self.ruler(of: controller)

        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(2, in: Self.text(lineCount: 3))) == 3)
        let thicknessBeforeReload = ruler.ruleThickness

        // The disk-reload path (TextDocument.applyText → controller.applyText)
        // replaces the text programmatically, exactly like the initial load.
        controller.applyText(reloadedText)

        #expect(ruler.lineNumber(forCharacterIndex: Self.startOfLine(reloadedLineCount - 1, in: reloadedText)) == reloadedLineCount)
        // Same observable delta as the open test: reloading a 150-line
        // document over a 3-line one widens the gutter by one digit; a stale
        // cache would keep it unchanged.
        #expect(abs(ruler.ruleThickness - thicknessBeforeReload - Self.digitAdvance) < 1)
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

    /// The selection's lines draw their number in the active color (#47): a
    /// bare caret lights its line, and a range lights every line it spans.
    @Test func gutterLightsTheSelectionsLines() throws {
        let text = Self.text(lineCount: 5)
        let document = try Self.document(withText: text)
        let controller = DocumentWindowController(document: document)
        let textView = try #require(try Self.scrollView(of: controller).documentView as? NSTextView)
        let ruler = try Self.ruler(of: controller)
        let string = text as NSString

        // A bare caret lights only its own line.
        textView.setSelectedRange(NSRange(location: Self.startOfLine(2, in: text), length: 0))
        #expect(ruler.selectedLineNumberRanges(of: textView, string: string) == [3...3])

        // A range lights every line it touches, first through last.
        textView.setSelectedRange(NSRange(
            location: Self.startOfLine(1, in: text),
            length: Self.startOfLine(3, in: text) - Self.startOfLine(1, in: text) + 1
        ))
        #expect(ruler.selectedLineNumberRanges(of: textView, string: string) == [2...4])
    }

    /// The line of the selection's final character is lit: selecting exactly
    /// line 2's trailing newline keeps line 2 active even though the next
    /// character already sits on line 3 (#47 review).
    @Test func gutterLightsTheLineAnEndingNewlineBelongsTo() throws {
        let text = Self.text(lineCount: 5)
        let document = try Self.document(withText: text)
        let controller = DocumentWindowController(document: document)
        let textView = try #require(try Self.scrollView(of: controller).documentView as? NSTextView)
        let ruler = try Self.ruler(of: controller)
        let string = text as NSString

        let line2 = string.lineRange(for: NSRange(location: Self.startOfLine(1, in: text), length: 0))
        textView.setSelectedRange(NSRange(location: NSMaxRange(line2) - 1, length: 1))
        #expect(ruler.selectedLineNumberRanges(of: textView, string: string) == [2...2])
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

    /// Advance of one digit at the editor font — the baseline the width
    /// deltas assert against, without re-deriving `updateThickness()`'s
    /// padding/sample formula here.
    static var digitAdvance: CGFloat {
        ("8" as NSString).size(withAttributes: [.font: editorFont]).width
    }
}
