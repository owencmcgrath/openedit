import AppKit

/// NSTextView with one discoverability tweak over stock AppKit: "Use Selection
/// for Find" (Cmd-E) normally stages the search term silently, which reads as
/// a no-op. This shows the find bar as well so the selection is visibly loaded.
/// Everything else stays native NSTextFinder behavior. See ARCHITECTURE.md 5.10.
///
/// Also hosts the LSP pointer plumbing (5.5): mouse-moved reports for hover
/// requests, and a tooltip provider that a window controller fills with the
/// diagnostic message under the pointer.
final class EditorTextView: NSTextView {
    /// Mouse-moved locations in view coordinates (tracking area installed
    /// below). The window controller debounces and turns these into hover
    /// requests.
    var onMouseMoved: ((NSPoint) -> Void)?

    /// Character index → diagnostic message, for native tooltips. `nil`/empty
    /// means no tooltip at that point.
    var diagnosticMessageProvider: ((Int) -> String?)?

    private var mouseTrackingArea: NSTrackingArea?
    private var toolTipTag: NSView.ToolTipTag?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area

        // Diagnostic-message tooltips (5.9) cover the whole (growing) view.
        if let toolTipTag {
            removeToolTip(toolTipTag)
        }
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMoved?(NSPoint(x: -1, y: -1))
    }

    /// NSView tooltip-owner method (called via `addToolTip`), not an override.
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let diagnosticMessageProvider,
              let layoutManager,
              let textContainer
        else { return "" }
        // `point` is in view coordinates; characterIndex(for:) expects text
        // container coordinates.
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return diagnosticMessageProvider(index) ?? ""
    }

    override func performTextFinderAction(_ sender: Any?) {
        super.performTextFinderAction(sender)

        guard let item = sender as? NSMenuItem,
              item.tag == NSTextFinder.Action.setSearchString.rawValue,
              selectedRange().length > 0
        else { return }

        let showFindInterface = NSMenuItem()
        showFindInterface.tag = NSTextFinder.Action.showFindInterface.rawValue
        super.performTextFinderAction(showFindInterface)
    }
}
