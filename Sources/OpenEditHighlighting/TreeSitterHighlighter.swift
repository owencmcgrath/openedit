import AppKit
import SwiftTreeSitter

/// Synchronous tree-sitter highlighting for one document (ARCHITECTURE.md 5.4,
/// 5.8). Owns a parser and the current syntax tree, re-parses incrementally on
/// edits, and applies dynamic `NSColor`s to the text storage.
///
/// Only the affected range is re-attributed on an ordinary edit: stale tokens in
/// that range are cleared and the tree-sitter captures that intersect it are
/// re-applied. `lastAppliedAttributeRange` exposes the range so callers and
/// tests can prove a whole-document re-attribute did not happen.
///
/// A missing language mapping or unbundled grammar leaves the highlighter
/// inactive: the text stays plain and editable, and `diagnostic` explains why.
public final class TreeSitterHighlighter {
    public private(set) var diagnostic: HighlightingDiagnostic?

    /// The range touched by the most recent attribute application. The initial
    /// full highlight reports the whole document; an incremental edit reports
    /// only the affected range.
    public private(set) var lastAppliedAttributeRange: NSRange?

    private let configuration: LanguageConfiguration?
    private let theme: SyntaxTheme
    private let parser = Parser()

    /// The syntax tree for the last parsed text, and the text it was parsed from
    /// (needed to compute edit points).
    private var tree: MutableTree?
    private var currentText = ""

    public var isActive: Bool { configuration != nil }

    /// Resolve `grammarName` through the bundled grammars. A `nil` name (no
    /// config entry for the file) is diagnosed rather than highlighted.
    public convenience init(
        grammarName: String?,
        fileExtension: String? = nil,
        registry: GrammarRegistry = GrammarRegistry(),
        theme: SyntaxTheme = .system
    ) {
        guard let grammarName else {
            self.init(diagnostic: .noLanguageMapping(fileExtension: fileExtension), theme: theme)
            return
        }

        switch registry.configuration(forGrammar: grammarName) {
        case let .success(configuration):
            self.init(configuration: configuration, theme: theme)
        case let .failure(diagnostic):
            self.init(diagnostic: diagnostic, theme: theme)
        }
    }

    /// A highlighter bound to an already-resolved grammar. `LanguageConfiguration`
    /// can be built from an explicit queries directory, which tests use.
    public init(configuration: LanguageConfiguration, theme: SyntaxTheme = .system) {
        self.configuration = configuration
        self.theme = theme
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            self.diagnostic = .queryLoadFailed(
                grammarName: configuration.name,
                message: "parser rejected language: \(error)"
            )
        }
    }

    /// An inactive highlighter that leaves text plain and records why.
    public init(diagnostic: HighlightingDiagnostic, theme: SyntaxTheme = .system) {
        self.configuration = nil
        self.theme = theme
        self.diagnostic = diagnostic
    }

    // MARK: - Highlighting

    /// Parse the full text and highlight all of it. Called on document open and
    /// after a programmatic reload replaces the text.
    public func highlightAll(in storage: NSTextStorage) {
        guard configuration != nil else { return }

        let text = storage.string
        tree = parser.parse(text)
        currentText = text

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        applyHighlights(in: storage, range: fullRange, text: text)
    }

    /// Re-parse incrementally after a user edit and re-apply attributes only to
    /// the affected range.
    ///
    /// `editedRange` and `changeInLength` are the values `NSTextStorage` reports
    /// from `didProcessEditing`: the changed range in the *new* text and
    /// `newLength - oldLength`.
    public func applyEdit(in storage: NSTextStorage, editedRange: NSRange, changeInLength: Int) {
        guard let configuration, configuration.queries[.highlights] != nil else { return }

        let newText = storage.string
        let oldText = currentText
        let newLength = (newText as NSString).length

        // New-text coordinates for the change; the old-text end is derived from
        // the length delta.
        let start = editedRange.location
        let newEnd = start + editedRange.length
        let oldEnd = newEnd - changeInLength

        let edit = InputEdit(
            startByte: start * 2,
            oldEndByte: oldEnd * 2,
            newEndByte: newEnd * 2,
            startPoint: Self.point(atUTF16Offset: start, in: oldText),
            oldEndPoint: Self.point(atUTF16Offset: oldEnd, in: oldText),
            newEndPoint: Self.point(atUTF16Offset: newEnd, in: newText)
        )

        let editedTree = tree
        editedTree?.edit(edit)
        let newTree = parser.parse(tree: editedTree, string: newText)
        tree = newTree
        currentText = newText

        // The changed range starts at the edit and grows to cover every subtree
        // tree-sitter says changed (a parent restructure can touch more than the
        // literal edit). Whole-line expansion keeps partially highlighted tokens
        // at the seam from lingering.
        var affected = NSRange(location: start, length: max(0, newEnd - start))
        if let editedTree, let newTree {
            for changedRange in newTree.changedRanges(from: editedTree) {
                affected = affected.union(changedRange.bytes.range)
            }
        }
        affected = Self.expandedToLines(affected, in: newText, documentLength: newLength)

        applyHighlights(in: storage, range: affected, text: newText)
    }

    private func applyHighlights(in storage: NSTextStorage, range: NSRange, text: String) {
        guard let configuration,
              let highlights = configuration.queries[.highlights],
              let tree
        else { return }

        let clampedRange = NSIntersectionRange(range, NSRange(location: 0, length: (text as NSString).length))
        guard clampedRange.length > 0 else { return }

        let cursor = highlights.execute(in: tree)
        let namedRanges = cursor.resolve(with: .init(string: text)).highlights()

        storage.beginEditing()
        // Reset the range to the dynamic default first so a token that lost its
        // syntax color (or text typed with an inherited color) does not keep a
        // stale one, then paint the captures in match order (less specific
        // first, more specific last — SwiftTreeSitter sorts them that way).
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: clampedRange)
        for namedRange in namedRanges {
            let colorRange = NSIntersectionRange(namedRange.range, clampedRange)
            guard colorRange.length > 0,
                  let color = theme.color(forCapture: namedRange.name)
            else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: colorRange)
        }
        storage.endEditing()

        lastAppliedAttributeRange = clampedRange
    }

    // MARK: - Geometry helpers

    /// UTF-16 offset to a tree-sitter point. Tree-sitter's runtime is driven in
    /// UTF-16LE, so byte offsets (and point columns) are twice the code-unit
    /// offset; rows count `\n`.
    private static func point(atUTF16Offset offset: Int, in text: String) -> Point {
        let string = text as NSString
        let clamped = max(0, min(offset, string.length))

        var row = 0
        var lineStart = 0
        var index = 0
        while index < clamped {
            if string.character(at: index) == 0x0A {
                row += 1
                lineStart = index + 1
            }
            index += 1
        }
        return Point(row: row, column: (clamped - lineStart) * 2)
    }

    /// Expand a range to whole lines so re-highlighting a token that straddles
    /// the edit boundary does not leave a half-colored remnant.
    private static func expandedToLines(_ range: NSRange, in text: String, documentLength: Int) -> NSRange {
        let string = text as NSString
        let clampedLocation = max(0, min(range.location, documentLength))
        let clampedEnd = max(clampedLocation, min(NSMaxRange(range), documentLength))

        let lineStart = string.lineRange(for: NSRange(location: clampedLocation, length: 0)).location
        let trailing = NSRange(
            location: clampedEnd,
            length: clampedEnd < documentLength ? 1 : 0
        )
        let lineEnd: Int
        if trailing.length == 0 {
            lineEnd = documentLength
        } else {
            lineEnd = NSMaxRange(string.lineRange(for: trailing))
        }

        return NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
    }
}
