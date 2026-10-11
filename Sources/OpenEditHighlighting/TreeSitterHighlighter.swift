import AppKit
import SwiftTreeSitter

/// Synchronous + incremental + progressive tree-sitter highlighting for one
/// document (ARCHITECTURE.md 5.4, 5.8). Owns a parser and the current syntax
/// tree, re-parses incrementally on edits, and applies dynamic `NSColor`s to
/// the text storage.
///
/// Open path (issue #38): documents up to `syncHighlightThreshold` UTF-16
/// units highlight synchronously (the original behavior, unchanged for the
/// overwhelmingly common small file). Larger documents skip attribute work on
/// the open path entirely — text renders immediately in the view's label
/// color — while a background job parses a private snapshot and hands back a
/// chunked capture list; the main queue then paints chunk by chunk, so the
/// window is interactive before the first capture lands. A user edit or
/// reload bumps the generation, which aborts any in-flight application and
/// re-enqueues the job against the current text, so colors always describe
/// the text on screen and typing during the initial parse is never blocked.
///
/// Only the affected range is re-attributed on an ordinary edit: stale tokens in
/// that range are cleared and the tree-sitter captures that intersect it are
/// re-applied. `lastAppliedAttributeRange` exposes the range so callers and
/// tests can prove a whole-document re-attribute did not happen.
///
/// A missing language mapping or unbundled grammar leaves the highlighter
/// inactive: the text stays plain and editable, and `diagnostic` explains why.
///
/// Main-actor isolated: every operation writes an `NSTextStorage`, which AppKit
/// requires on the main thread (5.11's one-window-per-document means the window
/// controller always calls from there).
@MainActor
public final class TreeSitterHighlighter {
    public private(set) var diagnostic: HighlightingDiagnostic?

    /// The range touched by the most recent attribute application. The initial
    /// full highlight reports the whole document; an incremental edit reports
    /// only the affected range.
    public private(set) var lastAppliedAttributeRange: NSRange?

    /// Documents at or below this length highlight synchronously on open
    /// (indistinguishable from instant); larger ones use the progressive path.
    public static let syncHighlightThreshold = 262_144

    private let configuration: LanguageConfiguration?
    private let theme: SyntaxTheme
    private let parser = Parser()

    /// The syntax tree for the last parsed text, and the text it was parsed from
    /// (needed to compute edit points).
    private var tree: MutableTree?
    private var currentText = ""

    /// Monotonic token for background jobs: anything that finishes out of date
    /// (an edit or reload landed meanwhile) is discarded and re-enqueued.
    private var generation = 0
    /// Outstanding background job (parse+collect) when non-nil.
    private var flightActive = false
    /// Pending progressive application, aborted by a generation bump.
    private var applicationGeneration: Int?
    private var applicationChunks: [[(NSRange, NSColor)]] = []
    private var applicationIndex = 0
    private var applicationStorage: NSTextStorage?

    public var isActive: Bool { configuration != nil }

    /// Resolve `grammarName` through the bundled grammars. A `nil` name (no
    /// config entry for the file) is diagnosed rather than highlighted.
    ///
    /// The `registry` default is the app's single shared instance
    /// (`GrammarRegistry.shared`): query directories resolve and highlight
    /// queries compile once for the app, not per document window.
    public convenience init(
        grammarName: String?,
        fileExtension: String? = nil,
        registry: GrammarRegistry = .shared,
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

    /// Parse the full text and highlight all of it, synchronously. The small
    /// document path (and the shape the unit tests drive directly).
    public func highlightAll(in storage: NSTextStorage) {
        guard configuration != nil else { return }

        let text = storage.string
        tree = parser.parse(text)
        currentText = text

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        applyHighlights(in: storage, range: fullRange, text: text)
    }

    /// Open/reload path for documents of any size (issue #38). Small documents
    /// take the synchronous path; large ones return immediately and colorize
    /// progressively from a background parse.
    public func beginOpenHighlight(in storage: NSTextStorage) {
        guard configuration != nil else { return }
        let text = storage.string
        if (text as NSString).length <= Self.syncHighlightThreshold {
            highlightAll(in: storage)
            return
        }
        beginProgressiveHighlight(storage: storage, text: text)
    }

    /// Kick off the background parse for a large document. Any in-flight
    /// application is aborted; its region keeps whatever attributes it has
    /// until the restarted pass repaints it.
    private func beginProgressiveHighlight(storage: NSTextStorage, text: String) {
        generation += 1
        applicationGeneration = nil
        applicationChunks = []
        applicationIndex = 0
        applicationStorage = storage
        flightActive = true

        let gen = generation
        let configuration = self.configuration!
        let theme = self.theme

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.parseAndCollect(text: text, configuration: configuration, theme: theme)
            DispatchQueue.main.async { [weak self] in
                self?.progressiveFlightCompleted(generation: gen, result: result, storage: storage)
            }
        }
    }

    /// Background-side work: parse a private snapshot and bucket its captures
    /// into application chunks. Runs entirely off-main against local state.
    private nonisolated static func parseAndCollect(
        text: String,
        configuration: LanguageConfiguration,
        theme: SyntaxTheme
    ) -> FlightResult {
        let parser = Parser()
        var tree: MutableTree?
        do {
            try parser.setLanguage(configuration.language)
            tree = parser.parse(text)
        } catch {
            tree = nil
        }

        var chunks: [[(NSRange, NSColor)]] = []
        if let tree, let highlights = configuration.queries[.highlights] {
            let cursor = highlights.execute(in: tree)
            let namedRanges = cursor.resolve(with: .init(string: text)).highlights()
            var collected: [(NSRange, NSColor)] = []
            // Cap protects against pathological documents flooding memory;
            // the remainder simply stays uncolored until a later pass.
            let captureCap = 4_000_000
            for namedRange in namedRanges where collected.count < captureCap {
                if let color = theme.color(forCapture: namedRange.name) {
                    collected.append((namedRange.range, color))
                }
            }
            // Query matches arrive grouped by pattern, not position; sort so
            // bucketing is positional.
            collected.sort { $0.0.location < $1.0.location }
            chunks = Self.bucket(collected)
        }
        return FlightResult(tree: tree, text: text, chunks: chunks)
    }

    /// Bucket sorted captures into `chunkUTF16Length` application units.
    private nonisolated static func bucket(
        _ captures: [(NSRange, NSColor)]
    ) -> [[(NSRange, NSColor)]] {
        var chunks: [[(NSRange, NSColor)]] = []
        var current: [(NSRange, NSColor)] = []
        var currentEnd = 0
        let chunkUTF16Length = 524_288
        for (range, color) in captures {
            if !current.isEmpty, range.location >= currentEnd {
                chunks.append(current)
                current = []
            }
            current.append((range, color))
            currentEnd = max(currentEnd, NSMaxRange(range))
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// One background parse result handed back to the main actor.
    private struct FlightResult {
        let tree: MutableTree?
        let text: String
        let chunks: [[(NSRange, NSColor)]]
    }

    private func progressiveFlightCompleted(
        generation gen: Int,
        result: FlightResult,
        storage: NSTextStorage
    ) {
        flightActive = false
        guard gen == generation else {
            // The document changed during the parse; re-enqueue against the
            // current text so colors eventually match what is on screen.
            beginProgressiveHighlight(storage: storage, text: storage.string)
            return
        }
        tree = result.tree
        currentText = result.text
        applicationChunks = result.chunks
        applicationIndex = 0
        applicationGeneration = gen
        scheduleNextApplicationChunk()
    }

    private func scheduleNextApplicationChunk() {
        guard let gen = applicationGeneration, gen == generation else { return }
        guard applicationIndex < applicationChunks.count else {
            applicationGeneration = nil
            return
        }
        let storage = applicationStorage
        DispatchQueue.main.async { [weak self] in
            self?.applyNextChunk(storage: storage)
        }
    }

    private func applyNextChunk(storage: NSTextStorage?) {
        guard let gen = applicationGeneration, gen == generation else { return }
        guard let storage, applicationIndex < applicationChunks.count else {
            applicationGeneration = nil
            return
        }
        applyChunk(storage: storage, captures: applicationChunks[applicationIndex])
        applicationIndex += 1
        scheduleNextApplicationChunk()
    }

    private func applyChunk(storage: NSTextStorage, captures: [(NSRange, NSColor)]) {
        guard let chunkRange = chunkBounds(captures, in: storage) else { return }
        storage.beginEditing()
        // Reset the chunk to the dynamic default first so stale colors never
        // survive a repaint, then paint captures in positional order.
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: chunkRange)
        for (range, color) in captures {
            let colorRange = NSIntersectionRange(range, chunkRange)
            guard colorRange.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: colorRange)
        }
        storage.endEditing()
        lastAppliedAttributeRange = chunkRange
    }

    private func chunkBounds(_ captures: [(NSRange, NSColor)], in storage: NSTextStorage) -> NSRange? {
        guard let first = captures.first else { return nil }
        let documentLength = (storage.string as NSString).length
        var start = max(0, first.0.location)
        var end = start
        for (range, _) in captures {
            start = min(start, max(0, range.location))
            end = max(end, min(documentLength, NSMaxRange(range)))
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: min(documentLength, end) - start)
    }

    /// Re-parse incrementally after a user edit and re-apply attributes only to
    /// the affected range.
    ///
    /// `editedRange` and `changeInLength` are the values `NSTextStorage` reports
    /// from `didProcessEditing`: the changed range in the *new* text and
    /// `newLength - oldLength`.
    public func applyEdit(in storage: NSTextStorage, editedRange: NSRange, changeInLength: Int) {
        guard let configuration, configuration.queries[.highlights] != nil else { return }

        // While a large-document parse is in flight there is no foreground tree
        // to edit against, and full-document parse per keystroke is exactly the
        // cost this path exists to avoid. Bump the generation so the in-flight
        // work is discarded and restarted against the settled text.
        if flightActive {
            generation += 1
            applicationGeneration = nil
            return
        }
        // A progressive application paints a stale snapshot; an edit makes it
        // obsolete. Abort it and schedule a fresh background pass — without
        // this restart the tail of the document would keep shifted, miscolored
        // attributes until the next open. The region the edit touched is
        // re-highlighted incrementally right below, so the edit is never plain
        // while waiting for the restarted pass.
        if applicationGeneration != nil {
            generation += 1
            applicationGeneration = nil
            applicationChunks = []
            applicationIndex = 0
            beginProgressiveHighlight(storage: storage, text: storage.string)
        }

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
