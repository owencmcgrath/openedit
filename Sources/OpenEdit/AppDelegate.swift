import AppKit
import OpenEditLSP

/// NSDocumentController subclass carrying the launch-settle behavior: Untitled
/// documents created by the launch machinery (AppKit's untitled-at-launch
/// pass and the bare-executable fallbacks all route through
/// `openUntitledDocumentAndDisplay`) are flagged on TextDocument, and the
/// first real-file open afterwards drops the empty ones — deterministically,
/// whenever the file arrives, instead of on a fixed timer.
final class OpenEditDocumentController: NSDocumentController {
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
        super.openDocument(
            withContentsOf: url,
            display: displayDocument
        ) { document, documentWasAlreadyOpen, error in
            if document != nil {
                TextDocument.settleLaunchedUntitledDocuments()
            }
            completionHandlerForDocuments(document, documentWasAlreadyOpen, error)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hasFinishedLaunching = false
    private var pendingOpenURLs: [URL] = []

    /// #8's single Settings window, created on first use.
    private var settingsWindowController: SettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The first NSDocumentController instance created becomes the shared
        // one; create ours before AppKit's finishLaunching machinery touches
        // `NSDocumentController.shared`.
        _ = OpenEditDocumentController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        hasFinishedLaunching = true

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
            openFile(at: url)
        }
        for url in pendingOpenURLs {
            openFile(at: url)
        }
        pendingOpenURLs.removeAll()

        // Bare `swift run` executables get no AppKit untitled-at-launch pass
        // (no Info.plist), so supply the Untitled window manually. Deferred
        // one run-loop turn so a launch argument file isn't raced.
        if !hasDocumentTypes, NSDocumentController.shared.documents.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, NSDocumentController.shared.documents.isEmpty else { return }
                self.openFile(at: nil)
            }
        }

        // Stray-untitled cleanup after launch needs no timer: file documents
        // arriving later (Open Documents Apple Events, slow mounts) settle the
        // launch-created Untitled themselves via
        // TextDocument.settleLaunchedUntitledDocuments().
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Backstop for the Untitled fallback in case activation is delayed; the
    /// Apple Event ordering note in applicationDidFinishLaunching applies.
    /// Bundled apps get the untitled pass from AppKit, so only the bare
    /// `swift run` executable (no Info.plist) uses this.
    func applicationDidBecomeActive(_ notification: Notification) {
        if !hasDocumentTypes, NSDocumentController.shared.documents.isEmpty {
            openFile(at: nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if hasFinishedLaunching {
            urls.forEach(openFile(at:))
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

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
        // Ask every live language server to shut down (ARCHITECTURE.md 5.5);
        // `shutdownAndExit` closes the process handles itself, so a slow or
        // unresponsive server cannot keep the app alive.
        Task { await LanguageServerPool.shared.shutdownAll() }
    }

    // MARK: - File opening

    private func openFile(at url: URL?) {
        if hasDocumentTypes {
            // Bundled app: NSDocumentController owns the open flow, including
            // deduping files that are already open and presenting load errors.
            if let canonicalURL = url?.resolvingSymlinksInPath() {
                NSDocumentController.shared.openDocument(
                    withContentsOf: canonicalURL,
                    display: true,
                    completionHandler: { _, _, error in
                        if let error {
                            NSDocumentController.shared.presentError(error)
                        }
                    }
                )
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

        createManualDocument(at: canonicalURL)
    }

    private func createManualDocument(at canonicalURL: URL?) {
        do {
            let newDocument = try canonicalURL.map { try TextDocument(fileAt: $0) } ?? TextDocument()
            NSDocumentController.shared.addDocument(newDocument)
            newDocument.makeWindowControllers()
            newDocument.showWindows()
            newDocument.windowControllers.forEach { $0.window?.makeKeyAndOrderFront(nil) }
            if canonicalURL == nil {
                // Same launch-settle flagging the bundled
                // OpenEditDocumentController applies to the Untitled fallback.
                newDocument.wasLaunchedUntitled = true
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
