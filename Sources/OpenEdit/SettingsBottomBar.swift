import AppKit

/// Shared bottom bar for both Settings tabs: the standard "?" help button on the
/// left and Done on the right (ARCHITECTURE.md 5.14). Settings apply
/// immediately, so Done only closes the window.
final class SettingsBottomBar: NSView {
    private let onHelp: () -> Void
    private let onDone: () -> Void

    init(onHelp: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.onHelp = onHelp
        self.onDone = onDone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let helpButton = NSButton(title: "?", target: self, action: #selector(helpClicked))
        helpButton.bezelStyle = .circular
        helpButton.toolTip = "About language server settings"
        helpButton.setAccessibilityLabel("Language server settings help")
        helpButton.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(helpButton)
        addSubview(doneButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),

            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            helpButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            helpButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    @objc private func helpClicked() {
        onHelp()
    }

    @objc private func doneClicked() {
        onDone()
    }
}

/// Top-left-origin document view for scroll views whose content is shorter than
/// the clip view.
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
