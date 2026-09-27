import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [DocumentWindowController] = []
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

        // The fallback for launching with no file at all defers one run-loop
        // turn: Open Documents Apple Events sent with a cold `open -a
        // OpenEdit.app somefile` are dispatched around the same time, and the
        // check keeps an extra Untitled window from appearing before them.
        if windowControllers.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.windowControllers.isEmpty else { return }
                self.openFile(at: nil)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Backstop for the Untitled fallback in case activation is delayed; the
    /// Apple Event ordering note in applicationDidFinishLaunching applies.
    func applicationDidBecomeActive(_ notification: Notification) {
        if windowControllers.isEmpty {
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

    // MARK: - File opening

    private func openFile(at url: URL?) {
        // Canonicalize so the same file opened via a launch argument and via
        // an Open Documents Apple Event (which resolve symlinks like
        // /var → /private/var differently) dedupes to one window.
        let canonicalURL = url?.resolvingSymlinksInPath()

        if let canonicalURL, let existing = windowControllers.first(where: { $0.fileURL == canonicalURL }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = DocumentWindowController(fileURL: canonicalURL)
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: controller.window
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === window }
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

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = makeEditMenu()
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
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
