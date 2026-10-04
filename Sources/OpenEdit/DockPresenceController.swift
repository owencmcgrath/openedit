import AppKit

/// Hides the Dock icon while no document windows are open and restores it when
/// one opens (ARCHITECTURE.md 5.13). The app deliberately outlives its windows
/// (`applicationShouldTerminateAfterLastWindowClosed` returns `false` — the CLI
/// shim, file watcher, and LSP pool all live in this process), so an idle,
/// windowless app has no reason to keep occupying the Dock.
///
/// Only document windows count. The Settings window (#8) does not keep the app
/// in the Dock: it is a transient auxiliary surface, not an editing session
/// (owner decision, #32).
final class DockPresenceController {
    /// Pure mapping from open-document-window count to the activation policy the
    /// app should advertise. `.regular` while at least one document window
    /// exists; `.accessory` once they are all gone — no Dock icon and no menu
    /// bar, but still reachable through the app switcher and the CLI.
    static func activationPolicy(forDocumentWindowCount count: Int) -> NSApplication.ActivationPolicy {
        count > 0 ? .regular : .accessory
    }

    /// True once the app has hidden its Dock icon (zero document windows). The
    /// AppDelegate consults this to suppress the Untitled backstop while the
    /// app is meant to be hidden.
    private(set) var isHidden = false

    private var observations: [NSObjectProtocol] = []

    /// Begin tracking document-window lifecycle. Call once, after the app's
    /// initial window exists: the observer only reacts to window events, so a
    /// windowless moment during launch never hides the Dock before the first
    /// window appears.
    func start() {
        let center = NotificationCenter.default
        observations.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.recompute()
        })
        observations.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.recompute()
        })
        observations.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // willClose arrives before the window leaves NSApp.windows; defer a
            // turn so the count reflects the completed close.
            DispatchQueue.main.async { self?.recompute() }
        })
    }

    /// Document windows only — a `DocumentWindowController`-owned window. A
    /// miniaturized window still exists in NSApp.windows and still counts, so
    /// the Dock icon never disappears out from under a window the user can only
    /// restore from the Dock.
    private func documentWindowCount() -> Int {
        NSApp.windows.filter { $0.windowController is DocumentWindowController }.count
    }

    private func recompute() {
        apply(Self.activationPolicy(forDocumentWindowCount: documentWindowCount()))
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        isHidden = policy == .accessory
        if policy == .regular {
            // Restoring the Dock icon: bring the app forward so the window that
            // triggered this is actually usable.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
