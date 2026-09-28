import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hasFinishedLaunching = false
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        hasFinishedLaunching = true

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

        // AppKit's untitled-at-launch pass runs before a cold-launch Open
        // Documents Apple Event is processed (and consults no delegate hook),
        // so `open -a OpenEdit.app somefile` gets an Untitled window the user
        // didn't ask for. Once the events have landed, drop any launch-created
        // untitled document that sits alongside real ones; keep it when the
        // launch really had no files.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.settleLaunchDocuments()
        }

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

    /// Close a launch-created Untitled document if the same launch also
    /// delivered file documents (AppKit's untitled pass ordered them first);
    /// an empty untitled TextDocument is unedited, so closing prompts nothing.
    private func settleLaunchDocuments() {
        let documents = NSDocumentController.shared.documents
        guard documents.count > 1,
              let untitled = documents.first(where: { ($0 as? TextDocument)?.fileURL == nil }) as? TextDocument
        else { return }
        untitled.close()
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
        } catch {
            NSDocumentController.shared.presentError(error)
        }
    }

    private var hasDocumentTypes: Bool {
        Bundle.main.infoDictionary?["CFBundleDocumentTypes"] != nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let controller = window.windowController as? DocumentWindowController,
              let textDocument = controller.textDocument
        else { return }
        // NSDocument normally closes itself once its last window goes away;
        // this async check is a no-op then, and a backstop otherwise.
        DispatchQueue.main.async { [weak textDocument] in
            guard let textDocument, textDocument.windowControllers.isEmpty else { return }
            NSDocumentController.shared.removeDocument(textDocument)
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
