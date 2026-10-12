import AppKit

/// Line-number gutter, implemented as an NSRulerView attached to the scroll
/// view's vertical ruler so AppKit tracks the text view's line-fragment
/// geometry automatically. See ARCHITECTURE.md 5.7.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let horizontalPadding: CGFloat = 6

    /// Character index at which each logical line starts, with a trailing
    /// entry for the empty line that follows a final newline. Cached so a
    /// redraw is O(log n) instead of rescanning the whole document from
    /// index 0 on every caret blink.
    ///
    /// Built by a single pass over a unichar buffer (issue #38: the previous
    /// per-line `lineRange(for:)` walk cost seconds on million-line files),
    /// and patched incrementally on edits via `noteCharactersEdited` so a
    /// keystroke never rescans the document.
    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false
    private var patchPendingForCurrentNotification = false

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)

        clientView = textView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(setNeedsRedraw),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(setNeedsRedraw),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        ensureLineStarts()

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        drawTrailingSeparator()

        let containerOrigin = textView.textContainerOrigin
        let visibleRect = scrollView.documentVisibleRect
            .offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)

        let string = textView.string as NSString
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let digitAdvance = ("0" as NSString).size(withAttributes: attributes).width

        let relativeOriginY = convert(NSPoint.zero, from: textView).y + containerOrigin.y

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            guard characterIndex == 0 || Self.isNewline(at: characterIndex - 1, in: string) else {
                // Wrapped continuation of a previous line: no number.
                return
            }
            self.draw(
                lineNumber: self.lineNumber(forCharacterIndex: characterIndex),
                atFragmentMinY: fragmentRect.minY,
                relativeOriginY: relativeOriginY,
                digitAdvance: digitAdvance,
                attributes: attributes
            )
        }

        // A final newline creates an empty trailing line that has no glyphs,
        // so enumerateLineFragments never reports it. Draw it explicitly so a
        // freshly opened line gets its number before the first keystroke.
        let extraRect = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer === textContainer,
           !extraRect.isEmpty,
           visibleRect.intersects(extraRect) {
            draw(
                lineNumber: lineNumber(forCharacterIndex: string.length),
                atFragmentMinY: extraRect.minY,
                relativeOriginY: relativeOriginY,
                digitAdvance: digitAdvance,
                attributes: attributes
            )
        }
    }

    @objc private func textDidChange() {
        if patchPendingForCurrentNotification {
            // The incremental patch in noteCharactersEdited already updated
            // lineStarts for this edit; a rescan here would erase the win.
            patchPendingForCurrentNotification = false
        } else {
            lineStartsValid = false
        }
        updateThickness()
        needsDisplay = true
    }

    @objc private func setNeedsRedraw() {
        needsDisplay = true
    }

    private func draw(
        lineNumber: Int,
        atFragmentMinY fragmentMinY: CGFloat,
        relativeOriginY: CGFloat,
        digitAdvance: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label = "\(lineNumber)" as NSString
        let width = digitAdvance * CGFloat(label.length)
        let point = NSPoint(
            x: ruleThickness - width - horizontalPadding,
            y: relativeOriginY + fragmentMinY
        )
        label.draw(at: point, withAttributes: attributes)
    }

    private func drawTrailingSeparator() {
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 1
        separator.stroke()
    }

    /// Widens the gutter when the file crosses a power-of-ten line count.
    private func updateThickness() {
        guard let textView, let font = textView.font else { return }

        ensureLineStarts()
        let digits = max(2, String(lineStarts.count).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        let newThickness = ceil(width) + horizontalPadding * 2

        if abs(newThickness - ruleThickness) > 0.5 {
            ruleThickness = newThickness
        }
    }

    private func ensureLineStarts() {
        guard !lineStartsValid, let textView else { return }
        lineStarts = Self.computeLineStarts(in: textView.string as NSString)
        lineStartsValid = true
    }

    /// Patch the cached line starts for one character edit (called from the
    /// window controller's `NSTextStorageDelegate` before the ruler's own
    /// `NSText.didChangeNotification` arrives). O(edited region), not O(doc).
    ///
    /// `range` is the edited range in the *new* text and `delta` is
    /// `newLength - oldLength`, exactly what `didProcessEditing` reports.
    func noteCharactersEdited(range: NSRange, delta: Int) {
        guard lineStartsValid, let textView else { return }

        let string = textView.string as NSString
        let documentLength = string.length
        let loc = max(0, min(range.location, documentLength))
        let newEnd = max(loc, min(NSMaxRange(range), documentLength))
        let oldEnd = max(loc, newEnd - delta)

        // Keep starts at or before the edit, drop starts strictly inside the
        // replaced region, and shift everything from the old region's end
        // (a start exactly at oldEnd is the line after the edit — kept).
        var shifted: [Int] = []
        shifted.reserveCapacity(lineStarts.count)
        var i = 0
        while i < lineStarts.count && lineStarts[i] <= loc {
            shifted.append(lineStarts[i])
            i += 1
        }
        while i < lineStarts.count && lineStarts[i] < oldEnd {
            i += 1
        }
        while i < lineStarts.count {
            shifted.append(lineStarts[i] + delta)
            i += 1
        }

        // New line starts inside the edited region, in new-text coordinates.
        var inserted: [Int] = []
        if newEnd > loc {
            var j = loc
            while j < newEnd {
                let c = string.character(at: j)
                // \r\n counts once, at the \n; every other newline unit
                // starts a line at j+1.
                let isRNLead = c == 0x0D && j + 1 < newEnd && string.character(at: j + 1) == 0x0A
                if Self.isNewlineCodeUnit(c), !isRNLead, j + 1 <= documentLength {
                    inserted.append(j + 1)
                }
                j += 1
            }
        }

        // Merge the shifted starts and the inserted starts in one linear pass
        // (both are sorted; equal values — e.g. an inserted start landing on a
        // kept boundary start at newEnd — must collapse to one entry).
        var merged: [Int] = []
        merged.reserveCapacity(shifted.count + inserted.count)
        var a = 0
        var b = 0
        while a < shifted.count || b < inserted.count {
            let nextShifted = a < shifted.count ? shifted[a] : Int.max
            let nextInserted = b < inserted.count ? inserted[b] : Int.max
            if nextShifted < nextInserted {
                merged.append(nextShifted)
                a += 1
            } else if nextInserted < nextShifted {
                if merged.last != nextInserted { merged.append(nextInserted) }
                b += 1
            } else {
                if merged.last != nextShifted { merged.append(nextShifted) }
                a += 1
                b += 1
            }
        }
        lineStarts = merged
        patchPendingForCurrentNotification = true
    }

    /// Character offsets where each logical line begins, via one pass over a
    /// unichar buffer. A final newline adds an entry at `string.length` for
    /// the empty line after it. The old per-line `lineRange(for:)` walk made
    /// million-line opens pay millions of ObjC bridge calls; this is a single
    /// linear scan (issue #38).
    private static func computeLineStarts(in string: NSString) -> [Int] {
        let length = string.length
        guard length > 0 else { return [0] }

        var buffer = [unichar](repeating: 0, count: length)
        string.getCharacters(&buffer, range: NSRange(location: 0, length: length))

        var starts: [Int] = [0]
        starts.reserveCapacity(max(16, length / 60 + 2))
        var i = 0
        while i < length {
            let c = buffer[i]
            if isNewlineCodeUnit(c) {
                // \r\n counts once, at the \n.
                let isRNLead = c == 0x0D && i + 1 < length && buffer[i + 1] == 0x0A
                if !isRNLead, i + 1 < length {
                    starts.append(i + 1)
                }
            }
            i += 1
        }
        if isNewlineCodeUnit(buffer[length - 1]) {
            starts.append(length)
        }
        return starts
    }

    /// Same newline set `NSString.lineRange` treats as breaks, as code units.
    private static func isNewlineCodeUnit(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D
            || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    /// 1-based line number containing `characterIndex`, via binary search over
    /// the cached line starts.
    private func lineNumber(forCharacterIndex characterIndex: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characterIndex {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    private static func isNewline(at characterIndex: Int, in string: NSString) -> Bool {
        guard characterIndex >= 0, characterIndex < string.length else { return true }
        guard let scalar = UnicodeScalar(string.character(at: characterIndex)) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}
