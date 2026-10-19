import AppKit
import OpenEditConfig
import OpenEditLSP

/// "Configuration" tab of #51's Settings window (ARCHITECTURE.md 5.14): the
/// config file location, one origin summary line, and the loader diagnostics. It
/// is informational — this window never writes `languages.toml`.
final class ConfigurationSettingsViewController: NSViewController {
    private let configURL = LanguageConfigLoader.defaultUserConfigURL

    private let configPathLabel = NSTextField(labelWithString: "")
    private let configStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let originLabel = NSTextField(labelWithString: "")
    private let diagnosticsStack = NSStackView()
    private let diagnosticsScrollView = NSScrollView()
    private let noDiagnosticsRow = NSStackView()

    private var model: LSPSettingsModel
    private let onOpenConfig: () -> Void
    private let onHelp: () -> Void
    private let onDone: () -> Void

    init(
        model: LSPSettingsModel,
        onOpenConfig: @escaping () -> Void,
        onHelp: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.model = model
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
        updateContent()
    }

    func apply(model: LSPSettingsModel) {
        self.model = model
        updateContent()
    }

    // MARK: - Content

    private func buildContentView(in root: NSView) {
        let configHeaderRow = sectionLabel("Config File")

        configPathLabel.stringValue = (configURL.path as NSString).abbreviatingWithTildeInPath
        configPathLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        configPathLabel.lineBreakMode = .byTruncatingMiddle
        configPathLabel.isSelectable = true
        configPathLabel.toolTip = configURL.path
        configPathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let openButton = NSButton(
            title: "Open languages.toml",
            target: self,
            action: #selector(openConfig(_:))
        )
        openButton.bezelStyle = .rounded
        openButton.toolTip = "Open your config, or reveal the folder when it does not exist yet."

        let pathRow = NSStackView(views: [configPathLabel, openButton])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 12

        configStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        configStatusLabel.textColor = .secondaryLabelColor
        configStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let explanation = NSTextField(
            wrappingLabelWithString: "OpenEdit reads this file over the bundled mappings and never writes it. "
                + "Invalid entries are skipped and listed below."
        )
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor

        originLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        originLabel.textColor = .secondaryLabelColor
        originLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        diagnosticsStack.orientation = .vertical
        diagnosticsStack.alignment = .width
        diagnosticsStack.spacing = 10
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false

        // A flipped document view keeps a short diagnostics list at the top of
        // the scroll area instead of floating it at the bottom (AppKit's default
        // non-flipped document coordinates).
        let diagnosticsDocumentView = FlippedDocumentView()
        diagnosticsDocumentView.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsDocumentView.autoresizingMask = [.width]
        diagnosticsDocumentView.addSubview(diagnosticsStack)
        diagnosticsScrollView.documentView = diagnosticsDocumentView
        diagnosticsScrollView.hasVerticalScroller = true
        diagnosticsScrollView.autohidesScrollers = true
        diagnosticsScrollView.drawsBackground = false
        diagnosticsScrollView.borderType = .noBorder
        diagnosticsScrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            diagnosticsStack.topAnchor.constraint(equalTo: diagnosticsDocumentView.topAnchor),
            diagnosticsStack.leadingAnchor.constraint(equalTo: diagnosticsDocumentView.leadingAnchor),
            diagnosticsStack.trailingAnchor.constraint(equalTo: diagnosticsDocumentView.trailingAnchor),
            diagnosticsStack.bottomAnchor.constraint(equalTo: diagnosticsDocumentView.bottomAnchor)
        ])

        let noDiagnosticsImage = NSImageView()
        noDiagnosticsImage.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: nil
        )
        noDiagnosticsImage.contentTintColor = .systemGreen
        noDiagnosticsImage.translatesAutoresizingMaskIntoConstraints = false
        noDiagnosticsImage.widthAnchor.constraint(equalToConstant: 14).isActive = true
        noDiagnosticsImage.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let noDiagnosticsLabel = NSTextField(labelWithString: "No configuration issues.")
        noDiagnosticsLabel.textColor = .secondaryLabelColor
        noDiagnosticsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        noDiagnosticsRow.orientation = .horizontal
        noDiagnosticsRow.alignment = .centerY
        noDiagnosticsRow.spacing = 6
        noDiagnosticsRow.addArrangedSubview(noDiagnosticsImage)
        noDiagnosticsRow.addArrangedSubview(noDiagnosticsLabel)
        noDiagnosticsRow.translatesAutoresizingMaskIntoConstraints = false

        let diagnosticsContainer = NSView()
        diagnosticsContainer.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        diagnosticsContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        diagnosticsContainer.addSubview(diagnosticsScrollView)
        diagnosticsContainer.addSubview(noDiagnosticsRow)

        NSLayoutConstraint.activate([
            diagnosticsScrollView.topAnchor.constraint(equalTo: diagnosticsContainer.topAnchor),
            diagnosticsScrollView.leadingAnchor.constraint(equalTo: diagnosticsContainer.leadingAnchor),
            diagnosticsScrollView.trailingAnchor.constraint(equalTo: diagnosticsContainer.trailingAnchor),
            diagnosticsScrollView.bottomAnchor.constraint(equalTo: diagnosticsContainer.bottomAnchor),

            noDiagnosticsRow.centerXAnchor.constraint(equalTo: diagnosticsContainer.centerXAnchor),
            noDiagnosticsRow.centerYAnchor.constraint(equalTo: diagnosticsContainer.centerYAnchor),
            noDiagnosticsRow.leadingAnchor.constraint(
                greaterThanOrEqualTo: diagnosticsContainer.leadingAnchor,
                constant: 20
            ),
            noDiagnosticsRow.trailingAnchor.constraint(
                lessThanOrEqualTo: diagnosticsContainer.trailingAnchor,
                constant: -20
            )
        ])

        let issuesLabel = sectionLabel("Configuration Issues")
        let contentStack = NSStackView(views: [
            configHeaderRow,
            pathRow,
            configStatusLabel,
            explanation,
            originLabel,
            separator(),
            issuesLabel,
            diagnosticsContainer
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        for label in [configHeaderRow, configStatusLabel, explanation, originLabel, issuesLabel] {
            label.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let footer = NSTextField(
            wrappingLabelWithString: "Changes apply to documents opened after a re-check. "
                + "Documents already open keep the server they were opened with."
        )
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let bottomBar = SettingsBottomBar(onHelp: onHelp, onDone: onDone)

        root.addSubview(contentStack)
        root.addSubview(footer)
        root.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    // MARK: - Content state

    private func updateContent() {
        let fileExists = FileManager.default.fileExists(atPath: configURL.path)
        configStatusLabel.stringValue = fileExists
            ? "Using your config file."
            : "No user config file; bundled defaults and the known-server catalog are in use."

        let rows = model.rows()
        let origins = rows.map(\.origin)
        let bundled = origins.filter { $0 == .bundled }.count
        let autodetected = origins.filter { $0 == .autodetected }.count
        let userConfigured = origins.filter { $0 == .userConfig }.count
        originLabel.stringValue = "Origins: Bundled \(bundled) \u{00B7} Autodetected \(autodetected) "
            + "\u{00B7} Your config \(userConfigured)"

        updateDiagnostics()
    }

    private func updateDiagnostics() {
        for view in diagnosticsStack.arrangedSubviews {
            diagnosticsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let diagnostics = model.allDiagnostics
        diagnosticsScrollView.isHidden = diagnostics.isEmpty
        noDiagnosticsRow.isHidden = !diagnostics.isEmpty

        for diagnostic in diagnostics {
            diagnosticsStack.addArrangedSubview(makeDiagnosticRow(for: diagnostic))
        }
    }

    private func makeDiagnosticRow(for diagnostic: LanguageConfigDiagnostic) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Configuration issue"
        )
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let label = NSTextField(wrappingLabelWithString: diagnostic.description)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    // MARK: - Actions

    @objc private func openConfig(_ sender: Any?) {
        onOpenConfig()
    }
}
