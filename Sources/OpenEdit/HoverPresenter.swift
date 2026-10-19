import AppKit

/// Shows `textDocument/hover` text in a transient popover anchored at the
/// pointer (ARCHITECTURE.md 5.5). One popover per window controller; the
/// caller decides when the text is presentable (version unchanged, pointer
/// still where the request was made).
final class HoverPresenter {
    private let popover = NSPopover()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    init() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 60)

        let controller = NSViewController()
        controller.view = scrollView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
    }

    var isShown: Bool { popover.isShown }

    /// Present `text` in a popover whose top-left sits near `point` in `view`.
    func show(_ text: String, at point: NSPoint, in view: NSView) {
        textView.string = text
        textView.sizeToFit()
        let fittingHeight = min(max(textView.frame.height, 28), 320)
        scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: fittingHeight)
        popover.show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .maxY)
    }

    func dismiss() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }
}
