import AppKit
import OpenEditConfig
import OpenEditLSP

/// #51's Settings window (ARCHITECTURE.md 5.14): a per-language language-server
/// dashboard over the same config snapshot and locator verdict the document open
/// path uses. Standard AppKit controls only, so it follows the system appearance
/// (5.8) with no theme code.
///
/// The window is resolution-state only by design: it does not show or control
/// live server processes. Re-check reloads the config file and re-probes PATH;
/// documents already open keep the registry snapshot they were opened with
/// (5.1).
final class SettingsWindowController: NSWindowController {
    private enum Column {
        static let language = NSUserInterfaceItemIdentifier("language")
        static let server = NSUserInterfaceItemIdentifier("server")
        static let notifications = NSUserInterfaceItemIdentifier("notifications")
    }

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let diagnosticsRow = NSStackView()
    private let diagnosticsLabel = NSTextField(labelWithString: "")

    private var model: LSPSettingsModel?
    private var displayedRows: [LSPSettingsRow] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 400)

        super.init(window: window)
        buildContentView()
        reload()
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
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Content

    private func buildContentView() {
        let title = NSTextField(labelWithString: "Languages & Servers")
        title.font = .preferredFont(forTextStyle: .title2)

        let subtitle = NSTextField(
            wrappingLabelWithString: "OpenEdit uses language servers it finds on your PATH and never installs them. "
                + "Language mapping lives in languages.toml."
        )
        subtitle.textColor = .secondaryLabelColor

        searchField.placeholderString = "Filter languages"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let recheckButton = NSButton(title: "Re-check", target: self, action: #selector(recheck(_:)))
        recheckButton.bezelStyle = .rounded
        recheckButton.toolTip = "Reload languages.toml and check PATH again."

        let openConfigButton = NSButton(
            title: "Open languages.toml",
            target: self,
            action: #selector(openConfigFile(_:))
        )
        openConfigButton.bezelStyle = .rounded
        openConfigButton.toolTip = "Open your config, or reveal the folder when it does not exist yet."

        let controlsSpacer = NSView()
        controlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [searchField, controlsSpacer, recheckButton, openConfigButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let warningImage = NSImageView()
        warningImage.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Configuration issue"
        )
        warningImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        warningImage.contentTintColor = .systemOrange
        warningImage.translatesAutoresizingMaskIntoConstraints = false
        warningImage.widthAnchor.constraint(equalToConstant: 14).isActive = true
        warningImage.heightAnchor.constraint(equalToConstant: 14).isActive = true

        diagnosticsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        diagnosticsLabel.textColor = .secondaryLabelColor

        let detailsButton = NSButton(
            title: "Show Details\u{2026}",
            target: self,
            action: #selector(showDiagnostics(_:))
        )
        detailsButton.bezelStyle = .inline

        let diagnosticsSpacer = NSView()
        diagnosticsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnosticsRow.orientation = .horizontal
        diagnosticsRow.alignment = .centerY
        diagnosticsRow.spacing = 6
        diagnosticsRow.addArrangedSubview(warningImage)
        diagnosticsRow.addArrangedSubview(diagnosticsLabel)
        diagnosticsRow.addArrangedSubview(diagnosticsSpacer)
        diagnosticsRow.addArrangedSubview(detailsButton)
        diagnosticsRow.isHidden = true

        let header = NSStackView(views: [title, subtitle, controls, diagnosticsRow])
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView's `.width` alignment stretches wrapping labels but not a
        // plain label with an intrinsic width; pin the title so it starts at the
        // leading edge instead of floating to the trailing one.
        title.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        let footer = NSTextField(
            wrappingLabelWithString: "Changes apply to documents opened after this window refreshes. "
                + "Documents that are already open keep the server they started with."
        )
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(header)
        contentView.addSubview(scrollView)
        contentView.addSubview(footer)
        contentView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20)
        ])
        window?.contentView = contentView
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.style = .inset
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 12, height: 2)

        let languageColumn = NSTableColumn(identifier: Column.language)
        languageColumn.title = "Language"
        languageColumn.width = 230
        languageColumn.minWidth = 170
        languageColumn.resizingMask = [.userResizingMask]
        tableView.addTableColumn(languageColumn)

        let serverColumn = NSTableColumn(identifier: Column.server)
        serverColumn.title = "Server"
        serverColumn.width = 420
        serverColumn.minWidth = 240
        serverColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(serverColumn)

        let notificationsColumn = NSTableColumn(identifier: Column.notifications)
        notificationsColumn.title = "Notify"
        notificationsColumn.width = 70
        notificationsColumn.minWidth = 70
        notificationsColumn.maxWidth = 90
        notificationsColumn.resizingMask = [.userResizingMask]
        tableView.addTableColumn(notificationsColumn)
    }

    // MARK: - Reload

    private func reload() {
        model = LSPSettingsModel()
        updateDiagnostics()
        reloadRows()
    }

    private func updateDiagnostics() {
        guard let model else { return }
        let diagnostics = model.allDiagnostics
        diagnosticsRow.isHidden = diagnostics.isEmpty
        guard !diagnostics.isEmpty else { return }
        diagnosticsLabel.stringValue = diagnostics.count == 1
            ? "1 configuration issue"
            : "\(diagnostics.count) configuration issues"
    }

    private func reloadRows() {
        displayedRows = model?.rows(matching: searchField.stringValue) ?? []
        tableView.reloadData()

        emptyLabel.isHidden = !displayedRows.isEmpty
        if displayedRows.isEmpty {
            emptyLabel.stringValue = searchField.stringValue.isEmpty
                ? "No languages configured."
                : "No languages match \u{201C}\(searchField.stringValue)\u{201D}."
        }
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: NSSearchField) {
        reloadRows()
    }

    @objc private func recheck(_ sender: Any?) {
        reload()
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        guard let languageID = sender.identifier?.rawValue else { return }
        model?.setNotificationsEnabled(sender.state == .on, for: languageID)
        updateDiagnostics()
        reloadRows()
    }

    @objc private func openConfigFile(_ sender: Any?) {
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
                self?.present(error)
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
            present(error)
        }
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        guard let diagnostics = model?.allDiagnostics, !diagnostics.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = diagnostics.count == 1
            ? "Configuration issue"
            : "\(diagnostics.count) configuration issues"
        alert.informativeText = diagnostics.map(\.description).joined(separator: "\n\n")
        alert.addButton(withTitle: "Open languages.toml")
        alert.addButton(withTitle: "Close")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.openConfigFile(nil)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Table content

    private func makeLanguageCell(for entry: LSPSettingsRow) -> NSView {
        let nameLabel = NSTextField(labelWithString: entry.displayName)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail

        let nameRow = NSStackView(views: [nameLabel])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 4

        if !entry.diagnostics.isEmpty {
            let warningImage = NSImageView()
            warningImage.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Configuration issue"
            )
            warningImage.contentTintColor = .systemOrange
            warningImage.toolTip = entry.diagnostics.map(\.description).joined(separator: "\n")
            warningImage.translatesAutoresizingMaskIntoConstraints = false
            warningImage.widthAnchor.constraint(equalToConstant: 13).isActive = true
            warningImage.heightAnchor.constraint(equalToConstant: 13).isActive = true
            nameRow.insertArrangedSubview(warningImage, at: 0)
        }

        let detail = languageDetail(for: entry)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.toolTip = detail

        let stack = NSStackView(views: [nameRow, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(stack)
        cell.textField = nameLabel
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeServerCell(for entry: LSPSettingsRow) -> NSView {
        let statusLabel = NSTextField(labelWithString: statusText(for: entry))
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        statusLabel.textColor = statusColor(for: entry)
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let detail = serverDetail(for: entry)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.toolTip = serverTooltip(for: entry)

        let stack = NSStackView(views: [statusLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeNotificationsCell(for entry: LSPSettingsRow) -> NSView {
        let cell = NSTableCellView()

        guard entry.canToggleNotifications else {
            let dash = NSTextField(labelWithString: "\u{2014}")
            dash.textColor = .tertiaryLabelColor
            dash.toolTip = "\(entry.displayName) is highlighting-only; no missing-server notice is posted."
            dash.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(dash)
            NSLayoutConstraint.activate([
                dash.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                dash.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        let checkbox = NSButton(
            checkboxWithTitle: "",
            target: self,
            action: #selector(toggleNotifications(_:))
        )
        checkbox.state = entry.isNotificationSuppressed ? .off : .on
        checkbox.identifier = NSUserInterfaceItemIdentifier(entry.languageID)
        checkbox.setAccessibilityLabel("Show missing server notice for \(entry.displayName)")
        checkbox.toolTip = entry.isNotificationSuppressed
            ? "The missing-server notice is dismissed for \(entry.displayName). Check to allow it again."
            : "Uncheck to dismiss the missing-server notice for \(entry.displayName)."
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - Row text

    private func languageDetail(for entry: LSPSettingsRow) -> String {
        guard entry.origin != nil else {
            return "Dismissed notice kept"
        }

        var parts: [String] = []
        if !entry.extensions.isEmpty {
            parts.append(entry.extensions.map { ".\($0)" }.joined(separator: ", "))
        }
        if let origin = entry.origin {
            parts.append(originLabel(for: origin))
        }
        return parts.isEmpty ? "No extensions" : parts.joined(separator: " \u{00B7} ")
    }

    private func originLabel(for origin: LSPSettingsOrigin) -> String {
        switch origin {
        case .bundled:
            return "Bundled"
        case .userConfig:
            return "Your config"
        case .autodetected:
            return "Autodetected"
        }
    }

    private func statusText(for entry: LSPSettingsRow) -> String {
        switch entry.status {
        case .available:
            return "Ready"
        case .missing:
            return "Not installed"
        case .highlightingOnly:
            return "Highlighting only"
        case .noLongerConfigured:
            return "No longer configured"
        }
    }

    private func statusColor(for entry: LSPSettingsRow) -> NSColor {
        switch entry.status {
        case .available:
            return .systemGreen
        case .missing:
            return .systemOrange
        case .highlightingOnly, .noLongerConfigured:
            return .secondaryLabelColor
        }
    }

    private func serverDetail(for entry: LSPSettingsRow) -> String {
        switch entry.status {
        case .available(let executablePath):
            return executablePath
        case .missing:
            if let lspPath = entry.lspPath, !lspPath.isEmpty {
                return "Not found at \(lspPath)"
            }
            if let installCommand = entry.installCommand, !installCommand.isEmpty {
                return "Install with: \(installCommand)"
            }
            if !entry.probedBinaries.isEmpty {
                return "Tried: \(entry.probedBinaries.joined(separator: ", "))"
            }
            return "The configured server was not found on PATH."
        case .highlightingOnly:
            return "No server configured; highlighting only."
        case .noLongerConfigured:
            return "This language has no config entry; its notice stays dismissed."
        }
    }

    private func serverTooltip(for entry: LSPSettingsRow) -> String {
        var lines = [serverDetail(for: entry)]
        if let lspPath = entry.lspPath, !lspPath.isEmpty, case .missing = entry.status {
            lines.append("Checked path: \(lspPath)")
        }
        if !entry.probedBinaries.isEmpty, case .missing = entry.status {
            lines.append("Checked for: \(entry.probedBinaries.joined(separator: ", "))")
        }
        if !entry.diagnostics.isEmpty {
            lines.append(contentsOf: entry.diagnostics.map(\.description))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, displayedRows.indices.contains(row) else { return nil }
        let entry = displayedRows[row]

        switch tableColumn.identifier {
        case Column.language:
            return makeLanguageCell(for: entry)
        case Column.server:
            return makeServerCell(for: entry)
        case Column.notifications:
            return makeNotificationsCell(for: entry)
        default:
            return nil
        }
    }
}
