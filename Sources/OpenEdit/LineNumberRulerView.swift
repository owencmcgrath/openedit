import AppKit

/// Line-number gutter, implemented as an NSRulerView attached to the scroll
/// view's vertical ruler so AppKit tracks the text view's line-fragment
/// geometry automatically. See ARCHITECTURE.md 5.7.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let horizontalPadding: CGFloat = 6

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

        let relativeOrigin = convert(NSPoint.zero, from: textView)

        let firstCharacterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        let firstLogicalLineStart = string
            .lineRange(for: NSRange(location: firstCharacterIndex, length: 0))
            .location
        var lineNumber = numberOfLines(before: firstLogicalLineStart, in: string)

        var isFirstFragment = true
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            let startsLogicalLine = characterIndex == 0 || self.isNewline(at: characterIndex - 1, in: string)

            if startsLogicalLine {
                self.draw(lineNumber: lineNumber, atFragmentMinY: fragmentRect.minY,
                          relativeOriginY: relativeOrigin.y + containerOrigin.y,
                          attributes: attributes)
                lineNumber += 1
            } else if isFirstFragment {
                // Visible top is a wrapped continuation; the next logical line
                // is one past the line this fragment belongs to.
                lineNumber += 1
            }

            isFirstFragment = false
        }

        // Empty documents have no line fragments to enumerate but should
        // still show line 1.
        if string.length == 0 {
            draw(lineNumber: 1, atFragmentMinY: 0,
                 relativeOriginY: relativeOrigin.y + containerOrigin.y,
                 attributes: attributes)
        }
    }

    @objc private func textDidChange() {
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
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label = "\(lineNumber)" as NSString
        let size = label.size(withAttributes: attributes)
        let point = NSPoint(
            x: ruleThickness - size.width - horizontalPadding,
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

        let lineCount = totalLineCount(in: textView.string as NSString)
        let digits = max(2, String(lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        let newThickness = ceil(width) + horizontalPadding * 2

        if abs(newThickness - ruleThickness) > 0.5 {
            ruleThickness = newThickness
        }
    }

    private func numberOfLines(before characterIndex: Int, in string: NSString) -> Int {
        var lineNumber = 1
        var location = 0
        while location < characterIndex {
            let next = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            if next <= location { break }
            location = next
            lineNumber += 1
        }
        return lineNumber
    }

    private func totalLineCount(in string: NSString) -> Int {
        var count = 1
        var location = 0
        while location < string.length {
            let next = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            if next <= location { break }
            if next < string.length { count += 1 }
            location = next
        }
        return count
    }

    private func isNewline(at characterIndex: Int, in string: NSString) -> Bool {
        guard characterIndex >= 0, characterIndex < string.length else { return true }
        guard let scalar = UnicodeScalar(string.character(at: characterIndex)) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}
