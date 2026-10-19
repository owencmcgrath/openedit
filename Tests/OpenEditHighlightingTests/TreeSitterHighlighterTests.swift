import AppKit
import Testing

@testable import OpenEditHighlighting

/// Acceptance coverage for ARCHITECTURE.md 5.4 / 5.8: tree-sitter highlighting
/// keyed off the config grammar mapping, the GitHub theme's dynamic colors,
/// incremental re-highlight limited to the affected range, and plain-text
/// fallback when the mapping or grammar is missing.
@Suite @MainActor struct TreeSitterHighlighterTests {
    private let theme = SyntaxTheme.github

    // MARK: - Helpers

    private func highlighting(_ grammar: String) -> TreeSitterHighlighter {
        TreeSitterHighlighter(grammarName: grammar, registry: GrammarRegistry(), theme: theme)
    }

    private func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text)
    }

    private func color(_ storage: NSTextStorage, at index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func isColored(_ storage: NSTextStorage, at index: Int, like capture: String) -> Bool {
        guard let actual = color(storage, at: index),
              let expected = theme.color(forCapture: capture)
        else { return false }
        return colorsEqual(actual, expected)
    }

    private func colorsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        if lhs.isEqual(rhs) { return true }
        return lhs.usingColorSpace(.sRGB)?.isEqual(rhs.usingColorSpace(.sRGB)) ?? false
    }

    private func range(of substring: String, in text: String) -> NSRange {
        (text as NSString).range(of: substring)
    }

    private func insert(_ inserted: String, at location: Int, in storage: NSTextStorage, highlighter: TreeSitterHighlighter) {
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: inserted)
        highlighter.applyEdit(
            in: storage,
            editedRange: NSRange(location: location, length: (inserted as NSString).length),
            changeInLength: (inserted as NSString).length
        )
    }

    private func delete(_ range: NSRange, in storage: NSTextStorage, highlighter: TreeSitterHighlighter) {
        storage.replaceCharacters(in: range, with: "")
        highlighter.applyEdit(
            in: storage,
            editedRange: NSRange(location: range.location, length: 0),
            changeInLength: -range.length
        )
    }

    private func pythonProgram() -> String {
        """
        import os


        class Greeter:
            def greet(self, name):
                return "hello " + name


        def main():
            value = 41 + 1
            print(value)
        """
    }

    // MARK: - Initial tokens in two grammars

    @Test func pythonInitialTokensAreHighlighted() {
        let source = "def add(a, b):\n    s = \"hi\"\n    return a + 42\n"
        let textStorage = storage(source)
        let highlighter = highlighting("python")

        #expect(highlighter.isActive)
        highlighter.highlightAll(in: textStorage)

        #expect(isColored(textStorage, at: range(of: "def", in: source).location, like: "keyword"))
        #expect(isColored(textStorage, at: range(of: "return", in: source).location, like: "keyword"))
        #expect(isColored(textStorage, at: range(of: "42", in: source).location, like: "number"))
        #expect(isColored(textStorage, at: range(of: "\"hi\"", in: source).location, like: "string"))
    }

    @Test func jsonInitialTokensAreHighlighted() {
        let source = "{\"key\": 42, \"ok\": true}"
        let textStorage = storage(source)
        let highlighter = highlighting("json")
        highlighter.highlightAll(in: textStorage)

        // `string.special.key` resolves through the `string.special` prefix entry.
        #expect(isColored(textStorage, at: range(of: "key", in: source).location, like: "string.special"))
        #expect(isColored(textStorage, at: range(of: "42", in: source).location, like: "number"))
        #expect(isColored(textStorage, at: range(of: "true", in: source).location, like: "constant.builtin"))
    }

    @Test func initialHighlightCoversWholeDocument() {
        let source = pythonProgram()
        let textStorage = storage(source)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        #expect(highlighter.lastAppliedAttributeRange == NSRange(location: 0, length: (source as NSString).length))
    }

    // MARK: - Incremental edits

    @Test func singleLineInsertRehighlightsOnlyAffectedRange() {
        let source = "alpha = 1\nbeta = 2\ngamma = 3\n"
        let textStorage = storage(source)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        let insertionPoint = range(of: "beta", in: source).location
        insert("def beta():", at: insertionPoint, in: textStorage, highlighter: highlighter)

        let totalLength = (textStorage.string as NSString).length
        let applied = highlighter.lastAppliedAttributeRange
        #expect(applied != nil)
        #expect(applied != NSRange(location: 0, length: totalLength))
        #expect((applied?.length ?? totalLength) < totalLength)
        // The inserted keyword is colored, and the edit is inside the range.
        #expect(isColored(textStorage, at: insertionPoint, like: "keyword"))
        #expect(NSLocationInRange(insertionPoint, applied ?? NSRange()))
        // A token far from the edit keeps its initial attribute.
        #expect(isColored(textStorage, at: range(of: "3", in: textStorage.string).location, like: "number"))
    }

    @Test func multilineInsertHighlightsInsertedBlock() {
        let source = pythonProgram()
        let textStorage = storage(source)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        let block = "def added():\n    return 7\n"
        let insertionPoint = range(of: "def main", in: source).location
        insert(block, at: insertionPoint, in: textStorage, highlighter: highlighter)

        let totalLength = (textStorage.string as NSString).length
        #expect(highlighter.lastAppliedAttributeRange != NSRange(location: 0, length: totalLength))
        #expect(isColored(textStorage, at: insertionPoint, like: "keyword"))
        #expect(isColored(textStorage, at: range(of: "7", in: textStorage.string).location, like: "number"))
    }

    @Test func deleteEditKeepsDocumentConsistent() {
        let source = "alpha = 1\nbeta = 2\ngamma = 3\n"
        let textStorage = storage(source)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        let lineRange = (source as NSString).range(of: "beta = 2\n")
        delete(lineRange, in: textStorage, highlighter: highlighter)

        let totalLength = (textStorage.string as NSString).length
        #expect(highlighter.lastAppliedAttributeRange != NSRange(location: 0, length: totalLength))
        #expect(textStorage.string == "alpha = 1\ngamma = 3\n")
        #expect(isColored(textStorage, at: range(of: "gamma", in: textStorage.string).location, like: "variable"))
        #expect(isColored(textStorage, at: range(of: "3", in: textStorage.string).location, like: "number"))
    }

    @Test func sequentialEditsStayCorrect() {
        let source = "a = 1\nb = 2\nc = 3\n"
        let textStorage = storage(source)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        insert("def f():", at: 0, in: textStorage, highlighter: highlighter)
        insert("return 5\n", at: (textStorage.string as NSString).range(of: "b = 2").location, in: textStorage, highlighter: highlighter)
        delete((textStorage.string as NSString).range(of: "c = 3\n"), in: textStorage, highlighter: highlighter)

        #expect(isColored(textStorage, at: 0, like: "keyword"))
        #expect(isColored(textStorage, at: range(of: "return", in: textStorage.string).location, like: "keyword"))
        #expect(isColored(textStorage, at: range(of: "1", in: textStorage.string).location, like: "number"))
    }

    @Test func editAtDocumentEnd() {
        let source = "alpha = 1\nbeta = 2\n"
        let textStorage = storage(source)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        let end = (textStorage.string as NSString).length
        insert("\ngamma = 99", at: end, in: textStorage, highlighter: highlighter)

        let totalLength = (textStorage.string as NSString).length
        let applied = highlighter.lastAppliedAttributeRange
        #expect(applied != nil)
        #expect(NSMaxRange(applied ?? NSRange()) == totalLength)
        #expect((applied?.length ?? totalLength) < totalLength)
        #expect(isColored(textStorage, at: range(of: "99", in: textStorage.string).location, like: "number"))
    }

    @Test func editAroundNonASCIIUsesUTF16Offsets() {
        let source = "name = \"héllo ünïcode\"\nother = 1\n"
        let textStorage = storage(source)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        let stringStart = range(of: "\"héllo", in: source).location
        #expect(isColored(textStorage, at: stringStart, like: "string"))

        // Insert a non-ASCII char inside the string; offsets stay UTF-16 based.
        insert("🚀", at: stringStart + 1, in: textStorage, highlighter: highlighter)
        #expect(textStorage.string == "name = \"🚀héllo ünïcode\"\nother = 1\n")
        #expect(isColored(textStorage, at: stringStart, like: "string"))
        #expect(isColored(textStorage, at: range(of: "1", in: textStorage.string).location, like: "number"))

        // Delete the emoji pair (two UTF-16 units) and re-check.
        delete(NSRange(location: stringStart + 1, length: 2), in: textStorage, highlighter: highlighter)
        #expect(textStorage.string == source)
        #expect(isColored(textStorage, at: stringStart, like: "string"))
    }

    // MARK: - Undo / redo

    @Test func highlightingDoesNotDisturbUndoHistory() {
        let textStorage = storage("x = 1\ny = 2\n")
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        // Simulate the undo history a user edit would leave behind, with the
        // inverse registered so redo is meaningful too.
        let undoManager = UndoManager()
        let original = textStorage.string
        let insertionPoint = (original as NSString).length
        textStorage.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: "\nz = 3")
        let edited = textStorage.string
        undoManager.registerUndo(withTarget: textStorage) { storage in
            storage.replaceCharacters(
                in: NSRange(location: 0, length: (storage.string as NSString).length),
                with: original
            )
            undoManager.registerUndo(withTarget: storage) { target in
                target.replaceCharacters(
                    in: NSRange(location: 0, length: (target.string as NSString).length),
                    with: edited
                )
            }
        }
        undoManager.setActionName("Insert")

        // The highlighter's attribute pass must not clear or consume that history.
        highlighter.applyEdit(
            in: textStorage,
            editedRange: NSRange(location: insertionPoint, length: 6),
            changeInLength: 6
        )
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(textStorage.string == original)
        undoManager.redo()
        #expect(textStorage.string == edited)
    }

    // MARK: - Fallbacks when mapping/grammar is missing

    @Test func unmappedExtensionFallsBackToPlainText() {
        let highlighter = TreeSitterHighlighter(grammarName: nil, fileExtension: "zzz")
        #expect(!highlighter.isActive)
        #expect(highlighter.diagnostic == .noLanguageMapping(fileExtension: "zzz"))

        let textStorage = storage("hello = 1\n")
        highlighter.highlightAll(in: textStorage)
        #expect(color(textStorage, at: 0) == nil)
    }

    @Test func missingGrammarFallsBackToPlainText() {
        let highlighter = TreeSitterHighlighter(grammarName: "cobol")
        #expect(!highlighter.isActive)
        #expect(highlighter.diagnostic == .grammarNotBundled(grammarName: "cobol"))

        let textStorage = storage("IDENTIFICATION DIVISION.\n")
        highlighter.highlightAll(in: textStorage)
        #expect(color(textStorage, at: 0) == nil)
    }

    // MARK: - Appearance

    @Test func themeColorsAreDynamicAcrossAppearances() {
        guard let label = theme.color(forCapture: "variable"),
              let lightAppearance = NSAppearance(named: .aqua),
              let darkAppearance = NSAppearance(named: .darkAqua)
        else {
            Issue.record("missing color or appearances")
            return
        }

        let light = resolved(label, in: lightAppearance)
        let dark = resolved(label, in: darkAppearance)
        #expect(light != nil && dark != nil)
        #expect(light != dark)
    }

    /// The GitHub palette is pinned to exact Primer hex values, per
    /// appearance (ARCHITECTURE.md 5.8): a drift back to system colors, or a
    /// light/dark mix-up in `githubColor`, fails here.
    @Test func githubThemePinsPrimerHexesPerAppearance() {
        guard let lightAppearance = NSAppearance(named: .aqua),
              let darkAppearance = NSAppearance(named: .darkAqua)
        else {
            Issue.record("missing appearances")
            return
        }

        // `capture: nil` means the theme's default foreground.
        let expectations: [(capture: String?, light: UInt32, dark: UInt32)] = [
            (nil, 0x1F2328, 0xE6EDF3),       // editor.foreground — fg.default
            ("keyword", 0xCF222E, 0xFF7B72), // scale.red[5] / red[3]
            ("string", 0x0A3069, 0xA5D6FF),  // scale.blue[8] / blue[1]
            ("number", 0x0550AE, 0x79C0FF),  // scale.blue[6] / blue[2]
            ("type.builtin", 0x0550AE, 0x79C0FF), // `support`: builtin types ride the blue stop
            ("comment", 0x6E7781, 0x8B949E), // scale.gray[5] / gray[3]
            ("function", 0x8250DF, 0xD2A8FF),// scale.purple[5] / purple[2]
            ("type", 0x953800, 0xFFA657),    // scale.orange[6] / orange[2]
            ("tag", 0x116329, 0x7EE787)      // scale.green[6] / green[1]
        ]

        for expectation in expectations {
            let color = expectation.capture.map { theme.color(forCapture: $0) } ?? theme.foreground
            #expect(
                hex(of: color, in: lightAppearance) == expectation.light,
                "light \(expectation.capture ?? "foreground")"
            )
            #expect(
                hex(of: color, in: darkAppearance) == expectation.dark,
                "dark \(expectation.capture ?? "foreground")"
            )
        }
    }

    private func hex(of color: NSColor?, in appearance: NSAppearance) -> UInt32? {
        guard let color, let resolved = resolved(color, in: appearance) else { return nil }
        let byte = { (component: CGFloat) -> UInt32 in
            UInt32((min(1, max(0, component)) * 255).rounded())
        }
        let red = byte(resolved.redComponent) << 16
        let green = byte(resolved.greenComponent) << 8
        let blue = byte(resolved.blueComponent)
        return red | green | blue
    }

    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return resolved
    }

    // MARK: - Attributes survive find and selection

    @Test func syntaxAttributesSurviveFindTemporaryAttributesAndSelection() {
        let source = "def add(a, b):\n    return a + 1\n"
        let textStorage = storage(source)
        let layoutManager = makeLayoutManager(for: textStorage)
        let highlighter = highlighting("python")
        highlighter.highlightAll(in: textStorage)

        let keywordIndex = range(of: "def", in: source).location
        let original = color(textStorage, at: keywordIndex)
        #expect(original != nil)

        // NSTextFinder highlights matches with temporary layout-manager
        // attributes, which must not overwrite the storage's syntax color.
        let matchRange = range(of: "add", in: source)
        layoutManager.addTemporaryAttributes([.foregroundColor: NSColor.systemYellow], forCharacterRange: matchRange)
        #expect(isColored(textStorage, at: keywordIndex, like: "keyword"))
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: matchRange)
        #expect(isColored(textStorage, at: keywordIndex, like: "keyword"))

        // Selection is drawn, not stored, so it cannot clobber syntax either.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: layoutManager.textContainers.first)
        textView.setSelectedRange(matchRange)
        #expect(isColored(textStorage, at: keywordIndex, like: "keyword"))
    }

    @discardableResult
    private func makeLayoutManager(for textStorage: NSTextStorage) -> NSLayoutManager {
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        return layoutManager
    }
}
