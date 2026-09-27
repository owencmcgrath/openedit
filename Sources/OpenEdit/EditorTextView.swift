import AppKit

/// NSTextView with one discoverability tweak over stock AppKit: "Use Selection
/// for Find" (Cmd-E) normally stages the search term silently, which reads as
/// a no-op. This shows the find bar as well so the selection is visibly loaded.
/// Everything else stays native NSTextFinder behavior. See ARCHITECTURE.md 5.10.
final class EditorTextView: NSTextView {
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
