import AppKit
import OpenEditConfig
import OpenEditLSP

/// #8's Settings window (ARCHITECTURE.md 5.6): the app menu's Settings item and
/// its standard Cmd-, shortcut open this single window, which lists each
/// language whose missing-LSP notice has been dismissed and offers one Reset
/// control per language. Standard AppKit controls only, so it follows the system
/// appearance (5.8) with no theme code.
final class SettingsWindowController: NSWindowController {
    private let entriesStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No language server notices are dismissed.")
    private let settings: MissingLSPDismissalSettings

    init(
        settings: MissingLSPDismissalSettings = MissingLSPDismissalSettings(
            registry: DocumentLanguageMapping.registry
        )
    ) {
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        buildContentView()
        reloadEntries()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reload the list from persistence (it may have changed while the app ran),
    /// then bring the one window forward.
    func present() {
        reloadEntries()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Content

    private func buildContentView() {
        let title = NSTextField(labelWithString: "Missing Language Server Notices")
        title.font = .preferredFont(forTextStyle: .headline)

        let subtitle = NSTextField(
            wrappingLabelWithString: "Languages you dismissed with \u{201C}Don't show again\u{201D}. "
                + "Resetting one allows its notice on the next file you open."
        )
        subtitle.textColor = .secondaryLabelColor

        entriesStack.orientation = .vertical
        entriesStack.alignment = .width
        entriesStack.spacing = 6

        emptyLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, subtitle, entriesStack, emptyLabel])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])
        window?.contentView = contentView
    }

    private func reloadEntries() {
        for view in entriesStack.arrangedSubviews {
            entriesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let entries = settings.entries()
        emptyLabel.isHidden = !entries.isEmpty
        for entry in entries {
            entriesStack.addArrangedSubview(makeRow(for: entry))
        }
    }

    private func makeRow(for entry: MissingLSPDismissalEntry) -> NSView {
        let name = entry.isConfigured
            ? entry.displayName
            : "\(entry.displayName) \u{2014} no longer configured"
        let label = NSTextField(labelWithString: name)

        let resetButton = NSButton(
            title: "Reset",
            target: self,
            action: #selector(resetLanguage(_:))
        )
        resetButton.bezelStyle = .rounded
        resetButton.identifier = NSUserInterfaceItemIdentifier(entry.languageID)

        let row = NSStackView(views: [label, NSView(), resetButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    @objc private func resetLanguage(_ sender: NSButton) {
        guard let languageID = sender.identifier?.rawValue else { return }
        settings.reset(languageID: languageID)
        reloadEntries()
    }
}
