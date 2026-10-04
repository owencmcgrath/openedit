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

    /// True while the app has hidden its Dock icon. Read from the app's actual
    /// activation policy rather than a cached copy, so it stays correct even if
    /// AppKit (or later code) flips the policy outside this controller. The
    /// AppDelegate consults this to suppress the Untitled backstop while the app
    /// is meant to be hidden.
    var isHidden: Bool {
        NSApp.activationPolicy() == .accessory
    }

    private var observations: [NSObjectProtocol] = []

    /// Begin tracking document-window lifecycle. Idempotent: a second call is a
    /// no-op. Call once after launch. Launch itself is deliberately not
    /// reconciled — doing so would hide the Dock during the windowless moment
    /// before the initial window appears (bare `swift run` creates its Untitled
    /// window in a deferred block in `AppDelegate`), and the observers only
    /// react to window events thereafter.
    func start() {
        guard observations.isEmpty else { return }
        let center = NotificationCenter.default
        observations.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard Self.isDocumentWindow(note.object) else { return }
            self?.recompute()
        })
        observations.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard Self.isDocumentWindow(note.object) else { return }
            self?.recompute()
        })
        observations.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.windowController is DocumentWindowController else { return }
            // Recompute synchronously, excluding the window still mid-close, so
            // the count reflects the completed close without depending on the
            // window having left `NSApp.windows` by the next run-loop turn.
            self?.recompute(excluding: window)
        })
    }

    deinit {
        let center = NotificationCenter.default
        observations.forEach { center.removeObserver($0) }
    }

    private static func isDocumentWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.windowController is DocumentWindowController
    }

    /// Document windows only — a `DocumentWindowController`-owned window. The
    /// Settings window is excluded by construction. A miniaturized window still
    /// exists in `NSApp.windows` and still counts, so the Dock icon never
    /// disappears out from under a window the user can only restore from the
    /// Dock. `excluding` skips a window that is mid-close and therefore still
    /// present in `NSApp.windows`.
    private func documentWindowCount(excluding excluded: NSWindow? = nil) -> Int {
        NSApp.windows.filter {
            $0 !== excluded && $0.windowController is DocumentWindowController
        }.count
    }

    private func recompute(excluding excluded: NSWindow? = nil) {
        apply(Self.activationPolicy(forDocumentWindowCount: documentWindowCount(excluding: excluded)))
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular, !NSApp.isActive {
            // Restoring the Dock icon: bring the app forward only when it is not
            // already frontmost, so a restore does not re-activate (and steal
            // focus from) the app the user is actually working in.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
