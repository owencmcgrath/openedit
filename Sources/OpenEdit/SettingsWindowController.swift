import AppKit
import OpenEditConfig
import OpenEditLSP

/// #51's Settings window (ARCHITECTURE.md 5.14): a native two-tab pane with a
/// toolbar tab bar ("Languages" and "Configuration") and a shared bottom
/// help/Done bar. The window is resolution-state only; it never edits language
/// config or controls live server processes.
final class SettingsWindowController: NSWindowController {
    private var model = LSPSettingsModel()
    private var serversViewController: ServersSettingsViewController?
    private var configurationViewController: ConfigurationSettingsViewController?
    private var tabViewController: NSTabViewController?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 520)

        super.init(window: window)
        buildTabs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reload the config and availability verdicts, then bring the one window
    /// forward. Both happen on every present so a server installed or a config
    /// edited while the app ran is reflected without a relaunch.
    func present() {
        reload()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Tabs

    private func buildTabs() {
        let servers = ServersSettingsViewController(
            model: model,
            onRecheck: { [weak self] in self?.reload() },
            onShowConfiguration: { [weak self] in self?.showConfiguration() },
            onOpenConfig: { [weak self] in self?.openConfigFile() },
            onHelp: { [weak self] in self?.showHelp() },
            onDone: { [weak self] in self?.done() }
        )
        let configuration = ConfigurationSettingsViewController(
            model: model,
            onOpenConfig: { [weak self] in self?.openConfigFile() },
            onHelp: { [weak self] in self?.showHelp() },
            onDone: { [weak self] in self?.done() }
        )
        serversViewController = servers
        configurationViewController = configuration

        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar

        let serversItem = NSTabViewItem(viewController: servers)
        serversItem.label = "Languages"
        serversItem.image = NSImage(
            systemSymbolName: "character.bubble",
            accessibilityDescription: "Languages"
        )
        tabViewController.addTabViewItem(serversItem)

        let configurationItem = NSTabViewItem(viewController: configuration)
        configurationItem.label = "Configuration"
        configurationItem.image = NSImage(
            systemSymbolName: "doc.text",
            accessibilityDescription: "Configuration"
        )
        tabViewController.addTabViewItem(configurationItem)

        self.tabViewController = tabViewController
        window?.contentViewController = tabViewController
        window?.toolbarStyle = .unified
        window?.toolbar?.displayMode = .iconAndLabel
        window?.toolbar?.sizeMode = .regular
        window?.setContentSize(NSSize(width: 780, height: 640))
    }

    private func showConfiguration() {
        tabViewController?.selectedTabViewItemIndex = 1
    }

    // MARK: - Model

    private func reload() {
        model = LSPSettingsModel()
        serversViewController?.apply(model: model)
        configurationViewController?.apply(model: model)
    }

    // MARK: - Actions

    private func done() {
        window?.close()
    }

    private func openConfigFile() {
        let configURL = LanguageConfigLoader.defaultUserConfigURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: configURL.path) {
            // Route through NSDocumentController so the config opens in OpenEdit
            // (with the TOML grammar) rather than whichever app owns .toml.
            NSDocumentController.shared.openDocument(
                withContentsOf: configURL,
                display: true
            ) { [weak self] _, _, error in
                guard let error else { return }
                self?.showError(error)
            }
            return
        }

        // No file yet: reveal the folder so the user can create one. Creating the
        // directory is harmless; creating a config file would be a config write,
        // which this window deliberately does not do (5.14).
        let directory = configURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            showError(error)
        }
    }

    private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Language Server Settings"
        alert.informativeText = "OpenEdit detects language servers on your PATH and never installs them. "
            + "The bundled known-server catalog adds autodetection for common languages. "
            + "Your languages.toml overrides bundled mappings; invalid entries are skipped and "
            + "listed in Configuration. Copy on a row puts the resolved server path or install "
            + "command on the clipboard."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Configuration")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertSecondButtonReturn {
                self?.showConfiguration()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
