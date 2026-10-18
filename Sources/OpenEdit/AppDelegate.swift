import AppKit
import OpenEditLSP
import OpenEditLog
import OpenEditWindowing

/// NSDocumentController subclass that owns document placement and the
/// launch-settle behavior.
///
/// Placement (ARCHITECTURE.md 5.1): AppKit delivers file-open Apple Events
/// (`odoc`) straight to this controller, not through the app delegate (which
/// only sees URL-scheme opens), so this override is the seam where
/// reuse-vs-new-window is decided. It reads `pendingIntent` for programmatic
/// opens (the `--new-window` opt-out) and defaults to reuse. It forces
/// `display: false` on the superclass so it can tab a reusing document into the
/// frontmost window instead of letting NSDocumentController order a new window
/// front.
///
/// Launch-settle: Untitled documents created by the launch machinery are
/// flagged on TextDocument, and the first real-file open afterwards drops the
/// empty ones — deterministically, whenever the file arrives, instead of on a
/// fixed timer.
final class OpenEditDocumentController: NSDocumentController {
    /// Intent for the next programmatic open. AppKit's odoc handling calls
    /// `openDocument` directly, so a plain file open leaves this `nil` and
    /// defaults to reuse; the CLI's `--new-window` opt-out sets it first.
    static var pendingIntent: OpenIntent?

    override func openUntitledDocumentAndDisplay(_ display: Bool) throws -> NSDocument {
        let document = try super.openUntitledDocumentAndDisplay(display)
        if let textDocument = document as? TextDocument, textDocument.fileURL == nil {
            textDocument.wasLaunchedUntitled = true
        }
        return document
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler completionHandlerForDocuments: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        let intent = Self.pendingIntent ?? .reuseExistingWindow
        Self.pendingIntent = nil
        // Resolve the reuse target before the open can make a new window
        // frontmost. A new-window intent always resolves to a new window, so
        // skip the window scan the router would discard anyway.
        let reuseTarget = intent == .newWindow ? nil : DocumentPlacement.reuseTarget(for: intent)
        let canonicalURL = url.standardizedFileURL
        let pendingOptions = TextDocument.pendingOpenOptions[canonicalURL]
        let pendingSelection = TextDocument.pendingOpenSelections[canonicalURL]

        super.openDocument(
            withContentsOf: url,
            display: false
        ) { document, documentWasAlreadyOpen, error in
            if document != nil {
                TextDocument.settleLaunchedUntitledDocuments()
            }
            if let textDocument = document as? TextDocument {
                // A re-open does not call `read`, so apply the options and
                // selection that the read path would otherwise have consumed
                // (ARCHITECTURE.md 5.1).
                if let pendingOptions {
                    textDocument.applyOpenOptions(pendingOptions)
                    TextDocument.pendingOpenOptions.removeValue(forKey: canonicalURL)
                }
                if let pendingSelection {
                    textDocument.applyInitialSelection(pendingSelection)
                    TextDocument.pendingOpenSelections.removeValue(forKey: canonicalURL)
                }
            }
            if let document, error == nil {
                if document.windowControllers.isEmpty {
                    document.makeWindowControllers()
                }
                if let controller = document.windowControllers.first {
                    if documentWasAlreadyOpen {
                        // Dedup: bring the existing window forward (5.1).
                        controller.showWindow(nil)
                        controller.window?.makeKeyAndOrderFront(nil)
                    } else {
                        DocumentPlacement.present(
                            controller,
                            intent: intent,
                            reusing: reuseTarget,
                            activate: !(pendingOptions?.background ?? false)
                        )
                    }
                    (controller as? DocumentWindowController)?.applyInitialSelection()
                }
            }
            completionHandlerForDocuments(document, documentWasAlreadyOpen, error)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True once AppKit is tearing the process down; closing documents during
    /// quit must not pollute the `--reopen` stack.
    static var isTerminating = false

    private var hasFinishedLaunching = false
    private var pendingOpenURLs: [URL] = []
    private var launchRequestsBackground = false

    /// #8's single Settings window, created on first use.
    private var settingsWindowController: SettingsWindowController?

    /// Hides the Dock icon while no document windows are open (ARCHITECTURE.md
    /// 5.13).
    private let dockPresence = DockPresenceController()

    /// Follows the system light/dark appearance for the app icon.
    private let appIcon = AppIconController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The first NSDocumentController instance created becomes the shared
        // one; create ours before AppKit's finishLaunching machinery touches
        // `NSDocumentController.shared`.
        _ = OpenEditDocumentController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        hasFinishedLaunching = true

        // Match the Dock/app-switcher icon to the system light/dark appearance.
        appIcon.start()

        // Remove stdin/wait artifacts left behind by a crashed shim or app
        // (ARCHITECTURE.md 5.1).
        sweepStaleTempFiles()

        // Track document-window open/close to toggle the Dock icon
        // (ARCHITECTURE.md 5.13).
        dockPresence.start()

        // Route server notifications (diagnostics) to the owning window
        // (ARCHITECTURE.md 5.9); each controller filters by its document URI.
        LanguageServerPool.shared.onServerNotification = { _, message in
            AppDelegate.routeServerNotification(message)
        }

        // Request notification authorization at first launch (ARCHITECTURE.md
        // 5.6); denial never blocks opening files. The notifier also asks again
        // lazily before a notice, in case this runs before the user decides.
        MissingLSPServerNotification.shared.start()

        for url in launchArgumentURLs() {
            openFile(at: url, intent: .reuseExistingWindow, options: OpenDocumentOptions())
        }
        for url in pendingOpenURLs {
            handleOpenURL(url)
        }
        pendingOpenURLs.removeAll()

        // Bare `swift run` executables get no AppKit untitled-at-launch pass
        // (no Info.plist), so supply the Untitled window manually. Deferred
        // one run-loop turn so a launch argument file isn't raced.
        if !hasDocumentTypes, NSDocumentController.shared.documents.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, NSDocumentController.shared.documents.isEmpty else { return }
                self.openFile(at: nil, intent: .reuseExistingWindow, options: OpenDocumentOptions())
            }
        }

        // Stray-untitled cleanup after launch needs no timer: file documents
        // arriving later (Open Documents Apple Events, slow mounts) settle the
        // launch-created Untitled themselves via
        // TextDocument.settleLaunchedUntitledDocuments().
        if !launchRequestsBackground {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Backstop for the Untitled fallback in case activation is delayed; the
    /// Apple Event ordering note in applicationDidFinishLaunching applies.
    /// Bundled apps get the untitled pass from AppKit, so only the bare
    /// `swift run` executable (no Info.plist) uses this. Suppressed while the
    /// app is deliberately hidden (ARCHITECTURE.md 5.13): activating a
    /// windowless app from the app switcher must not resurrect a window — and
    /// with it the Dock icon — until the user opens a file.
    func applicationDidBecomeActive(_ notification: Notification) {
        if !hasDocumentTypes, !dockPresence.isHidden, NSDocumentController.shared.documents.isEmpty {
            openFile(at: nil, intent: .reuseExistingWindow, options: OpenDocumentOptions())
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if hasFinishedLaunching {
            urls.forEach(handleOpenURL(_:))
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    /// Route one Apple Event URL: an `openedit://` request carries an explicit
    /// intent (the `--new-window` opt-out, ARCHITECTURE.md 5.1); anything else
    /// is a plain file open, which defaults to reusing the frontmost window.
    private func handleOpenURL(_ url: URL) {
        if let request = OpenURLInterpreter.interpret(url) {
            configureLogging(from: request.options)
            if request.action == .reopen {
                if let url = ReopenStore.shared.popLastClosed() {
                    openFile(at: url, intent: request.intent, options: request.options)
                }
                return
            }
            if request.targets.isEmpty, request.options.isScratch {
                openFile(at: nil, intent: request.intent, options: request.options)
                return
            }
            for target in request.targets {
                openFile(
                    at: target.fileURL,
                    intent: request.intent,
                    options: request.options,
                    selection: target.selection
                )
            }
        } else if url.scheme?.lowercased() != OpenURLScheme.scheme {
            // A plain file URL defaults to reusing the frontmost window. A
            // recognized-but-unparseable `openedit://` URL is ignored rather
            // than treated as a file, which would surface a bogus "not found".
            openFile(at: url, intent: .reuseExistingWindow, options: OpenDocumentOptions())
        } else {
            OpenEditLog.shared.warning(
                category: "app",
                "ignoring malformed openedit URL: \(url.absoluteString)"
            )
        }
    }

    /// Apply `--log-level`/`--log-file`/`--debug` to the process logger; the
    /// newest CLI invocation wins (ARCHITECTURE.md 5.1).
    private func configureLogging(from options: OpenDocumentOptions) {
        if options.background {
            launchRequestsBackground = true
        }
        var level: OpenEditLogLevel?
        if options.debug {
            level = .debug
        } else if let name = options.logLevel, let parsed = OpenEditLogLevel(name: name) {
            level = parsed
        }
        let fileURL = options.logFilePath.map { URL(fileURLWithPath: $0) }
        if level != nil || fileURL != nil {
            OpenEditLog.shared.configure(level: level, fileURL: fileURL)
            OpenEditLog.shared.info(
                category: "app",
                "logging configured (level: \(level?.name ?? "unchanged"), file: \(fileURL?.path ?? "unchanged"))"
            )
        }
    }

    /// File-open Apple Events (`odoc`) are handled by `NSDocumentController`
    /// (and thus `OpenEditDocumentController.openDocument`, the placement seam);
    /// URL-scheme opens arrive in `application(_:open:)` above.

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Fan a server notification out to every open document window; each
    /// controller ignores notifications for other documents.
    private static func routeServerNotification(_ message: JSONRPCMessage) {
        guard message.method == "textDocument/publishDiagnostics",
              let publish = DiagnosticsPublish.parse(params: message.params)
        else { return }
        for document in NSDocumentController.shared.documents {
            guard let textDocument = document as? TextDocument else { continue }
            for controller in textDocument.windowControllers.compactMap({ $0 as? DocumentWindowController }) {
                controller.applyDiagnostics(publish)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.isTerminating = true
        // Ask every live language server to shut down (ARCHITECTURE.md 5.5);
        // `shutdownAndExit` closes the process handles itself, so a slow or
        // unresponsive server cannot keep the app alive.
        Task { await LanguageServerPool.shared.shutdownAll() }
    }

    // MARK: - File opening

    private func openFile(
        at url: URL?,
        intent: OpenIntent,
        options: OpenDocumentOptions,
        selection: TextSelection? = nil
    ) {
        if hasDocumentTypes {
            // Bundled app: NSDocumentController owns the open flow (including
            // odoc file-open Apple Events, which reach
            // `OpenEditDocumentController.openDocument`, the placement seam).
            // Record the intent and per-open options for that override, then
            // open; it decides reuse-vs-new-window and presents the document
            // (ARCHITECTURE.md 5.1).
            if let canonicalURL = url?.resolvingSymlinksInPath() {
                OpenEditDocumentController.pendingIntent = intent
                TextDocument.pendingOpenOptions[canonicalURL.standardizedFileURL] = options
                if let selection {
                    TextDocument.pendingOpenSelections[canonicalURL.standardizedFileURL] = selection
                }
                NSDocumentController.shared.openDocument(
                    withContentsOf: canonicalURL,
                    display: true,
                    completionHandler: { _, _, error in
                        if let error {
                            NSDocumentController.shared.presentError(error)
                        }
                    }
                )
            } else if options.isScratch {
                openScratchDocument(intent: intent, options: options)
            } else {
                do {
                    _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
                } catch {
                    NSDocumentController.shared.presentError(error)
                }
            }
            return
        }

        // Bare `swift run` executable: Bundle.main has no Info.plist, so the
        // NSDocumentController type machinery can't resolve files; manage
        // TextDocuments directly instead.
        let canonicalURL = url?.resolvingSymlinksInPath()

        if let canonicalURL,
           let existing = NSDocumentController.shared.documents.first(where: {
               ($0 as? TextDocument)?.fileURL == canonicalURL
           }) as? TextDocument {
            existing.showWindows()
            existing.windowControllers.forEach { $0.window?.makeKeyAndOrderFront(nil) }
            return
        }

        createManualDocument(at: canonicalURL, intent: intent, options: options, selection: selection)
    }

    /// A deliberate CLI scratch buffer in the bundled app. Unlike the
    /// launch-created Untitled document, it is not a launch artifact and must
    /// survive the first real file open.
    private func openScratchDocument(intent: OpenIntent, options: OpenDocumentOptions) {
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            guard let textDocument = document as? TextDocument else { return }
            textDocument.wasLaunchedUntitled = false
            textDocument.applyOpenOptions(options)
            if document.windowControllers.isEmpty {
                document.makeWindowControllers()
            }
            guard let controller = document.windowControllers.first else {
                document.showWindows()
                return
            }
            let reuseTarget = intent == .newWindow ? nil : DocumentPlacement.reuseTarget(for: intent)
            DocumentPlacement.present(
                controller,
                intent: intent,
                reusing: reuseTarget,
                activate: !options.background
            )
        } catch {
            NSDocumentController.shared.presentError(error)
        }
    }

    private func createManualDocument(
        at canonicalURL: URL?,
        intent: OpenIntent,
        options: OpenDocumentOptions,
        selection: TextSelection?
    ) {
        do {
            let reuseTarget = intent == .newWindow ? nil : DocumentPlacement.reuseTarget(for: intent)
            let newDocument: TextDocument
            if let canonicalURL {
                TextDocument.pendingOpenOptions[canonicalURL.standardizedFileURL] = options
                if let selection {
                    TextDocument.pendingOpenSelections[canonicalURL.standardizedFileURL] = selection
                }
                newDocument = try TextDocument(fileAt: canonicalURL)
            } else {
                newDocument = TextDocument()
                newDocument.applyOpenOptions(options)
            }
            NSDocumentController.shared.addDocument(newDocument)
            newDocument.makeWindowControllers()
            if let controller = newDocument.windowControllers.first {
                DocumentPlacement.present(
                    controller,
                    intent: intent,
                    reusing: reuseTarget,
                    activate: !options.background
                )
            } else {
                newDocument.showWindows()
            }
            if canonicalURL == nil {
                // Same launch-settle flagging the bundled
                // OpenEditDocumentController applies to the Untitled fallback,
                // except for a deliberate CLI scratch buffer.
                newDocument.wasLaunchedUntitled = !options.isScratch
            } else {
                // A newly arrived file document settles any launch-created
                // empty Untitled documents.
                TextDocument.settleLaunchedUntitledDocuments()
            }
        } catch {
            NSDocumentController.shared.presentError(error)
        }
    }

    private var hasDocumentTypes: Bool {
        Bundle.main.infoDictionary?["CFBundleDocumentTypes"] != nil
    }

    /// Drop old `openedit-stdin-*` / `openedit-wait-*` files from $TMPDIR. Only
    /// stale artifacts are removed; a live CLI wait (or a document opened
    /// minutes ago) keeps its file.
    private func sweepStaleTempFiles() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("openedit-stdin-") || name.hasPrefix("openedit-wait-") else {
                continue
            }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? manager.removeItem(at: entry)
        }
    }

    /// File paths supplied as launch arguments (e.g. `swift run OpenEdit <path>`
    /// or `open -n OpenEdit.app --args <path>`, per ARCHITECTURE.md 5.1).
    private func launchArgumentURLs() -> [URL] {
        CommandLine.arguments.dropFirst().compactMap { argument in
            guard !argument.hasPrefix("-") else { return nil }
            let url = URL(fileURLWithPath: argument).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // MARK: - Menu

    func buildMainMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeApplicationMenu())

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = makeFileMenu()
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = makeEditMenu()
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Open #8's Settings window, creating it lazily so the app pays nothing
    /// until the user asks. The window reloads dismissal state on each present.
    @objc private func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.present()
    }

    /// Save is explicit only (ARCHITECTURE.md 5.11): Cmd-S routes through the
    /// responder chain to NSDocument.save(_:) via standard dirty-state
    /// tracking, with no autosave.
    private func makeFileMenu() -> NSMenu {
        let fileMenu = NSMenu(title: "File")

        fileMenu.addItem(
            withTitle: "Save",
            action: #selector(NSDocument.save(_:)),
            keyEquivalent: "s"
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        return fileMenu
    }

    private func makeApplicationMenu() -> NSMenuItem {
        let appMenu = NSMenu(title: "OpenEdit")
        appMenu.addItem(
            withTitle: "About OpenEdit",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(
            withTitle: "Settings\u{2026}",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide OpenEdit",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit OpenEdit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let appMenuItem = NSMenuItem(title: "OpenEdit", action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    private func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(.separator())

        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findMenuItem.submenu = makeFindMenu()
        editMenu.addItem(findMenuItem)

        return editMenu
    }

    /// Find/replace actions are dispatched to the first responder through
    /// `NSTextView.performTextFinderAction(_:)`; tags select the NSTextFinder
    /// action. See ARCHITECTURE.md 5.10.
    private func makeFindMenu() -> NSMenu {
        let findMenu = NSMenu(title: "Find")

        addFindItem(
            to: findMenu,
            title: "Find…",
            keyEquivalent: "f",
            action: .showFindInterface
        )

        let replaceItem = addFindItem(
            to: findMenu,
            title: "Find and Replace…",
            keyEquivalent: "f",
            action: .showReplaceInterface
        )
        replaceItem.keyEquivalentModifierMask = [.command, .option]

        addFindItem(to: findMenu, title: "Find Next", keyEquivalent: "g", action: .nextMatch)
        addFindItem(to: findMenu, title: "Find Previous", keyEquivalent: "G", action: .previousMatch)
        findMenu.addItem(.separator())
        addFindItem(
            to: findMenu,
            title: "Use Selection for Find",
            keyEquivalent: "e",
            action: .setSearchString
        )

        return findMenu
    }

    @discardableResult
    private func addFindItem(
        to menu: NSMenu,
        title: String,
        keyEquivalent: String,
        action: NSTextFinder.Action
    ) -> NSMenuItem {
        let item = menu.addItem(
            withTitle: title,
            action: #selector(NSTextView.performTextFinderAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.tag = action.rawValue
        return item
    }
}
