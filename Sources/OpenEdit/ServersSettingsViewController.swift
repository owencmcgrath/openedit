import AppKit
import OpenEditLSP

/// "Languages" tab of #51's Settings window (ARCHITECTURE.md 5.14): a native
/// table-based inventory of every known language with its server status, the
/// resolved path or install command, and a trailing Copy action. Config origin
/// and diagnostics live in the Configuration tab.
final class ServersSettingsViewController: NSViewController {
    private enum Column {
        static let language = NSUserInterfaceItemIdentifier("language")
        static let server = NSUserInterfaceItemIdentifier("server")
        static let action = NSUserInterfaceItemIdentifier("action")
    }

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let diagnosticsRow = NSStackView()
    private let diagnosticsLabel = NSTextField(labelWithString: "")

    private var model: LSPSettingsModel
    private var displayedRows: [LSPSettingsRow] = []

    private let onRecheck: () -> Void
    private let onShowConfiguration: () -> Void
    private let onOpenConfig: () -> Void
    private let onHelp: () -> Void
    private let onDone: () -> Void

    init(
        model: LSPSettingsModel,
        onRecheck: @escaping () -> Void,
        onShowConfiguration: @escaping () -> Void,
        onOpenConfig: @escaping () -> Void,
        onHelp: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.model = model
        self.onRecheck = onRecheck
        self.onShowConfiguration = onShowConfiguration
        self.onOpenConfig = onOpenConfig
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

    /// Re-render from a fresh config load.
    func apply(model: LSPSettingsModel) {
        self.model = model
        updateDiagnostics()
        reloadRows()
    }

    private func updateDiagnostics() {
        let diagnostics = model.allDiagnostics
        diagnosticsRow.isHidden = diagnostics.isEmpty
        guard !diagnostics.isEmpty else { return }
        diagnosticsLabel.stringValue = diagnostics.count == 1
            ? "1 configuration issue"
            : "\(diagnostics.count) configuration issues"
    }

    // MARK: - Content

    private func buildContentView(in root: NSView) {
        let recheckButton = NSButton(title: "Re-check", target: self, action: #selector(recheck(_:)))
        recheckButton.bezelStyle = .rounded
        recheckButton.toolTip = "Reload languages.toml and check PATH again."

        let sectionLabel = NSTextField(labelWithString: "Language Servers")
        sectionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [sectionLabel, headerSpacer, recheckButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8

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

        let headerStack = NSStackView(views: [headerRow, diagnosticsRow])
        headerStack.orientation = .vertical
        headerStack.alignment = .width
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

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

        root.addSubview(headerStack)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(footer)
        root.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
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
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 12, height: 2)

        let languageColumn = NSTableColumn(identifier: Column.language)
        languageColumn.title = "Language"
        languageColumn.width = 220
        languageColumn.minWidth = 170
        languageColumn.resizingMask = [.userResizingMask]
        tableView.addTableColumn(languageColumn)

        let serverColumn = NSTableColumn(identifier: Column.server)
        serverColumn.title = "Server"
        serverColumn.width = 380
        serverColumn.minWidth = 240
        serverColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(serverColumn)

        let actionColumn = NSTableColumn(identifier: Column.action)
        actionColumn.title = ""
        actionColumn.width = 90
        actionColumn.minWidth = 90
        actionColumn.maxWidth = 110
        actionColumn.resizingMask = [.userResizingMask]
        tableView.addTableColumn(actionColumn)
    }

    private func reloadRows() {
        displayedRows = model.rows()
        tableView.reloadData()

        emptyLabel.isHidden = !displayedRows.isEmpty
        if displayedRows.isEmpty {
            emptyLabel.stringValue = "No languages configured."
        }
    }

    // MARK: - Table cells

    private func makeLanguageCell(for entry: LSPSettingsRow) -> NSView {
        let cell = NSTableCellView()

        let nameLabel = NSTextField(labelWithString: entry.displayName)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail

        let extensionsLabel = NSTextField(labelWithString: extensionsText(for: entry))
        extensionsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        extensionsLabel.textColor = .secondaryLabelColor
        extensionsLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [nameLabel, extensionsLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

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
        let cell = NSTableCellView()

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 4

        let statusLabel = NSTextField(labelWithString: statusText(for: entry))
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        statusLabel.textColor = statusColor(for: entry)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusRow.addArrangedSubview(statusLabel)

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
            statusRow.addArrangedSubview(warningImage)
        }

        let detail = serverDetail(for: entry)
        let detailLabel = NSTextField(labelWithString: detail)
        // Paths and commands read best in the system monospaced face; prose
        // states ("No install command configured") stay in the default face.
        detailLabel.font = entry.copyValue != nil
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.toolTip = serverTooltip(for: entry)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [statusRow, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeActionCell(for entry: LSPSettingsRow) -> NSView {
        let cell = NSTableCellView()

        guard entry.copyValue != nil || entry.needsOpenConfigAction else {
            return cell
        }

        let button: NSButton
        if entry.needsOpenConfigAction {
            button = NSButton(title: "Open Config", target: self, action: #selector(openConfig(_:)))
            button.setAccessibilityLabel("Open languages.toml to configure \(entry.displayName)")
            button.toolTip = "No install command is configured for \(entry.displayName); add one in languages.toml."
        } else {
            button = NSButton(title: "Copy", target: self, action: #selector(copyRowValue(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(entry.languageID)
            switch entry.status {
            case .available:
                button.setAccessibilityLabel("Copy the \(entry.displayName) server path")
                button.toolTip = "Copy the resolved server path."
            case .missing:
                button.setAccessibilityLabel("Copy the \(entry.displayName) install command")
                button.toolTip = "Copy the install command."
            case .highlightingOnly:
                break
            }
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: 4)
        ])
        return cell
    }

    // MARK: - Actions

    @objc private func recheck(_ sender: Any?) {
        onRecheck()
    }

    @objc private func reviewDiagnostics(_ sender: Any?) {
        onShowConfiguration()
    }

    @objc private func openConfig(_ sender: NSButton) {
        onOpenConfig()
    }

    @objc private func copyRowValue(_ sender: NSButton) {
        guard let languageID = sender.identifier?.rawValue,
              let entry = displayedRows.first(where: { $0.languageID == languageID }),
              let value = entry.copyValue
        else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak sender] in
            sender?.title = "Copy"
        }
    }

    // MARK: - Row text

    private func extensionsText(for entry: LSPSettingsRow) -> String {
        guard !entry.extensions.isEmpty else {
            return "No extensions"
        }
        return entry.extensions.map { ".\($0)" }.joined(separator: ", ")
    }

    private func statusText(for entry: LSPSettingsRow) -> String {
        switch entry.status {
        case .available:
            return "Server ready"
        case .missing:
            return "Server not installed"
        case .highlightingOnly:
            return "Highlighting only"
        }
    }

    private func statusImage(for entry: LSPSettingsRow) -> NSImage? {
        switch entry.status {
        case .available:
            return NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Ready")
        case .missing:
            return NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Not installed"
            )
        case .highlightingOnly:
            return NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlighting only")
        }
    }

    private func statusColor(for entry: LSPSettingsRow) -> NSColor {
        switch entry.status {
        case .available:
            return .systemGreen
        case .missing:
            return .systemOrange
        case .highlightingOnly:
            return .secondaryLabelColor
        }
    }

    private func serverDetail(for entry: LSPSettingsRow) -> String {
        switch entry.status {
        case .available(let executablePath):
            return executablePath
        case .missing:
            if entry.hasInstallCommand, let installCommand = entry.installCommand {
                return installCommand
            }
            return "No install command configured"
        case .highlightingOnly:
            return "No language server configured."
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
        case Column.action:
            return makeActionCell(for: entry)
        default:
            return nil
        }
    }
}