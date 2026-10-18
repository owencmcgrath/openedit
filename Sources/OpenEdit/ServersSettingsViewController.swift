import AppKit
import OpenEditConfig
import OpenEditLSP

/// "Languages" tab of #51's Settings window (ARCHITECTURE.md 5.14): the
/// per-language server dashboard over the same config snapshot and locator
/// verdict the document-open path uses.
final class ServersSettingsViewController: NSViewController {
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

    private var model: LSPSettingsModel
    private var displayedRows: [LSPSettingsRow] = []

    private let onRecheck: () -> Void
    private let onShowConfiguration: () -> Void
    private let onSetNotifications: (Bool, String) -> Void
    private let onHelp: () -> Void
    private let onDone: () -> Void

    init(
        model: LSPSettingsModel,
        onRecheck: @escaping () -> Void,
        onShowConfiguration: @escaping () -> Void,
        onSetNotifications: @escaping (Bool, String) -> Void,
        onHelp: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.model = model
        self.onRecheck = onRecheck
        self.onShowConfiguration = onShowConfiguration
        self.onSetNotifications = onSetNotifications
        self.onHelp = onHelp
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        view = root
        buildContentView(in: root)
        reloadRows()
    }

    /// Re-render from a fresh config load. The search text is kept, so Re-check
    /// does not clear an active filter.
    func apply(model: LSPSettingsModel) {
        self.model = model
        updateDiagnostics()
        reloadRows()
    }

    // MARK: - Content

    private func buildContentView(in root: NSView) {
        searchField.placeholderString = "Filter languages"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let recheckButton = NSButton(title: "Re-check", target: self, action: #selector(recheck(_:)))
        recheckButton.bezelStyle = .rounded
        recheckButton.toolTip = "Reload languages.toml and check PATH again."

        let searchSpacer = NSView()
        searchSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let searchRow = NSStackView(views: [searchField, searchSpacer, recheckButton])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8

        let hint = NSTextField(
            labelWithString: "Servers are detected on your PATH. OpenEdit never installs them."
        )
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)

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

        let reviewButton = NSButton(
            title: "Review\u{2026}",
            target: self,
            action: #selector(reviewDiagnostics(_:))
        )
        reviewButton.bezelStyle = .rounded
        reviewButton.controlSize = .small
        reviewButton.toolTip = "Show the config file and its issues in Configuration."

        let diagnosticsSpacer = NSView()
        diagnosticsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnosticsRow.orientation = .horizontal
        diagnosticsRow.alignment = .centerY
        diagnosticsRow.spacing = 6
        diagnosticsRow.addArrangedSubview(warningImage)
        diagnosticsRow.addArrangedSubview(diagnosticsLabel)
        diagnosticsRow.addArrangedSubview(diagnosticsSpacer)
        diagnosticsRow.addArrangedSubview(reviewButton)
        diagnosticsRow.isHidden = true

        let header = NSStackView(views: [searchRow, hint, diagnosticsRow])
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        let footer = NSTextField(
            wrappingLabelWithString: "Documents already open keep the server they were opened with."
        )
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let bottomBar = SettingsBottomBar(onHelp: onHelp, onDone: onDone)

        root.addSubview(header)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(footer)
        root.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20)
        ])
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

    private func updateDiagnostics() {
        let diagnostics = model.allDiagnostics
        diagnosticsRow.isHidden = diagnostics.isEmpty
        guard !diagnostics.isEmpty else { return }
        diagnosticsLabel.stringValue = diagnostics.count == 1
            ? "1 configuration issue"
            : "\(diagnostics.count) configuration issues"
    }

    private func reloadRows() {
        displayedRows = model.rows(matching: searchField.stringValue)
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
        onRecheck()
    }

    @objc private func reviewDiagnostics(_ sender: Any?) {
        onShowConfiguration()
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        guard let languageID = sender.identifier?.rawValue else { return }
        onSetNotifications(sender.state == .on, languageID)
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

extension ServersSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
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
