import AppKit
import OpenEditWindowing

/// Shared window-placement rules for opening a document (ARCHITECTURE.md 5.1):
/// reuse the frontmost document window by tabbing the new document into it, or
/// show a normal new window. The reuse-vs-new decision is the Foundation-only
/// `OpenPlacementRouter`; this type supplies the AppKit windows and tabbing.
enum DocumentPlacement {
    /// The window a reuse open should tab into, or `nil` when the intent asks
    /// for a new window or there is no reusable window to reuse.
    static func reuseTarget(for intent: OpenIntent) -> NSWindow? {
        let candidate = frontmostReusableDocumentWindow()
        let placement = OpenPlacementRouter.placement(
            intent: intent,
            hasReusableWindow: candidate != nil
        )
        return placement == .reuseExistingWindow ? candidate : nil
    }

    /// The frontmost document window the user could sensibly reuse: a
    /// `DocumentWindowController` window backed by a real file. Launch-created
    /// empty Untitled windows are skipped so a cold `openedit file` lands in a
    /// fresh window instead of tabbing into a throwaway.
    static func frontmostReusableDocumentWindow() -> NSWindow? {
        NSApp.orderedWindows.first { window in
            guard let controller = window.windowController as? DocumentWindowController,
                  let textDocument = controller.textDocument
            else { return false }
            return !textDocument.wasLaunchedUntitled
        }
    }

    /// Show a freshly opened document: tab it into `reuseTarget` when one is
    /// given, otherwise order its own window front. `intent` is needed to tell
    /// an explicit new-window open (which must not be auto-merged into an
    /// existing tab group) from a reuse open that simply found no window to
    /// reuse.
    static func present(
        _ controller: NSWindowController,
        intent: OpenIntent,
        reusing reuseTarget: NSWindow?
    ) {
        guard let window = controller.window else { return }
        if let reuseTarget, reuseTarget !== window {
            // The target may be a window from an earlier `.newWindow` open whose
            // identifier was cleared; restore the shared identifier so the two
            // windows can form a tab group.
            reuseTarget.tabbingIdentifier = DocumentWindowController.tabbingIdentifier
            reuseTarget.addTabbedWindow(window, ordered: .above)
        } else if intent == .newWindow {
            // An explicit new-window open must not be silently merged into an
            // existing tab group by AppKit's automatic window tabbing (the
            // user's "prefer tabs" setting). Clearing the shared identifier
            // makes the window ineligible for automatic tabbing
            // (ARCHITECTURE.md 5.1).
            window.tabbingIdentifier = ""
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
