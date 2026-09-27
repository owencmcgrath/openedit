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
    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false

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
        lineStartsValid = false
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

    /// Character offsets where each logical line begins. A final newline adds
    /// an entry at `string.length` for the empty line after it.
    private static func computeLineStarts(in string: NSString) -> [Int] {
        var starts = [0]
        var location = 0
        while location < string.length {
            let next = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            if next <= location { break }
            location = next
            if location < string.length { starts.append(location) }
        }
        if string.length > 0, isNewline(at: string.length - 1, in: string) {
            starts.append(string.length)
        }
        return starts
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
