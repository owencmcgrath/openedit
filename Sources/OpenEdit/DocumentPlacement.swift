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
    /// given, otherwise order its own window front.
    static func present(_ controller: NSWindowController, reusing reuseTarget: NSWindow?) {
        guard let window = controller.window else { return }
        if let reuseTarget, reuseTarget !== window {
            reuseTarget.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
