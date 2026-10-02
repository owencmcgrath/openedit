import AppKit
import OpenEditHighlighting
import OpenEditLSP

/// Window for one open document: the text view, scroll view, and gutter, with
/// user edits forwarded to the TextDocument for standard NSDocument dirty
/// tracking (ARCHITECTURE.md 5.11) and reloads pushed back in from the
/// document's watcher (5.3).
///
/// The window also owns the tree-sitter highlighter (5.4): `NSTextStorage`
/// character edits drive an incremental re-highlight, while the highlighter's
/// own attribute edits are ignored so they never register as document changes
/// or fight undo/find styling.
final class DocumentWindowController: NSWindowController, NSTextViewDelegate, NSTextStorageDelegate {
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let lineNumberRuler: LineNumberRulerView
    private let highlighter: TreeSitterHighlighter

    /// Diagnostics for this document (ARCHITECTURE.md 5.9), invalidated on
    /// every edit so underlines never describe stale text.
    private var diagnostics = DocumentDiagnostics()
    private let hoverPresenter = HoverPresenter()
    private var hoverTask: Task<Void, Never>?

    /// Guard so programmatic text application (initial load, silent reload,
    /// reload from the conflict prompt) is not counted as a user edit.
    private var isApplyingDocumentText = false

    /// Guard so attribute writes performed by the highlighter are not treated as
    /// user edits (they arrive as `didProcessEditing` with `.editedAttributes`).
    private var isApplyingHighlight = false

    var textDocument: TextDocument? {
        document as? TextDocument
    }

    init(document: TextDocument) {
        let textStorage = NSTextStorage()
        self.textStorage = textStorage
        let layoutManager = NSLayoutManager()
        self.layoutManager = layoutManager
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let editorTextView = EditorTextView(frame: .zero, textContainer: textContainer)
        textView = editorTextView
        editorTextView.minSize = NSSize(width: 0, height: 0)
        editorTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editorTextView.isVerticallyResizable = true
        editorTextView.isHorizontallyResizable = false
        editorTextView.autoresizingMask = [.width]
        editorTextView.textContainerInset = NSSize(width: 4, height: 4)
        editorTextView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editorTextView.allowsUndo = true
        editorTextView.isRichText = false
        editorTextView.isAutomaticQuoteSubstitutionEnabled = false
        editorTextView.isAutomaticDashSubstitutionEnabled = false
        editorTextView.isAutomaticTextReplacementEnabled = false
        editorTextView.isAutomaticSpellingCorrectionEnabled = false
        editorTextView.usesFindBar = true
        editorTextView.isIncrementalSearchingEnabled = true

        scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = editorTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        lineNumberRuler = LineNumberRulerView(textView: editorTextView, scrollView: scrollView)
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.center()
        window.setFrameAutosaveName("OpenEditDocumentWindow")
        window.title = document.displayName

        highlighter = TreeSitterHighlighter(
            grammarName: DocumentLanguageMapping.grammarName(for: document.fileURL),
            fileExtension: document.fileURL?.pathExtension
        )

        super.init(window: window)

        editorTextView.string = document.text
        editorTextView.undoManager?.removeAllActions()
        editorTextView.delegate = self
        editorTextView.onMouseMoved = { [weak self] point in
            self?.handleMouseMoved(point)
        }
        editorTextView.diagnosticMessageProvider = { [weak self] index in
            self?.diagnosticMessage(atUTF16Offset: index)
        }
        highlightAll()
        // Set last: the highlighter's own attribute writes must not be observed
        // as edits, and the initial full highlight is not a user edit.
        textStorage.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
    }

    /// Push disk-derived text into the view, clearing undo history that would
    /// otherwise try to undo edits into a document that no longer contains
    /// them. (The initializer reads document.text directly; this covers
    /// watcher-driven reloads.)
    func applyText(_ newText: String) {
        isApplyingDocumentText = true
        textView.string = newText
        textView.undoManager?.removeAllActions()
        highlightAll()
        isApplyingDocumentText = false
        clearDiagnostics()
    }

    // MARK: - Highlighting (ARCHITECTURE.md 5.4)

    private func highlightAll() {
        isApplyingHighlight = true
        highlighter.highlightAll(in: textStorage)
        isApplyingHighlight = false
    }

    /// Called after a character edit. The highlighter reparses incrementally and
    /// re-attributes only the affected range; `.editedAttributes` rounds (the
    /// highlighter's own writes) are ignored.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters),
              !isApplyingDocumentText,
              !isApplyingHighlight
        else { return }

        isApplyingHighlight = true
        highlighter.applyEdit(in: textStorage, editedRange: editedRange, changeInLength: delta)
        isApplyingHighlight = false
        clearDiagnostics()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingDocumentText, !isApplyingHighlight, let textDocument else { return }
        textDocument.noteTextEdited(textView.string)
    }

    // MARK: - Diagnostics and hover (ARCHITECTURE.md 5.5, 5.9)

    /// Accept a `publishDiagnostics` notification for this document. Pushes
    /// for other documents, docs the pool no longer serves, and pushes whose
    /// version does not match what the client last sent are ignored.
    func applyDiagnostics(_ publish: DiagnosticsPublish) {
        guard let fileURL = textDocument?.fileURL,
              publish.uri == FileURI.make(from: fileURL),
              let version = LanguageServerPool.shared.trackedVersion(fileURL: fileURL)
        else { return }
        guard diagnostics.accept(publish, currentVersion: version) else { return }
        renderDiagnostics()
    }

    private func clearDiagnostics() {
        hoverPresenter.dismiss()
        guard !diagnostics.diagnostics.isEmpty else { return }
        diagnostics.invalidate()
        renderDiagnostics()
    }

    private func renderDiagnostics() {
        let text = textView.string as NSString
        DiagnosticUnderliner.apply(
            diagnostics.renderable(in: text),
            to: layoutManager,
            textLength: text.length
        )
    }

    private func diagnosticMessage(atUTF16Offset index: Int) -> String? {
        diagnostics.diagnostic(atUTF16Offset: index, in: textView.string as NSString)?.message
    }

    /// Pointer moved in the text view: show a diagnostic's message directly, or
    /// (debounced) ask the server for hover text. The request is async, so
    /// typing is never blocked; a response that loses a race with an edit or a
    /// new pointer position is dropped.
    private func handleMouseMoved(_ point: NSPoint) {
        hoverTask?.cancel()
        hoverTask = nil

        guard point.x >= 0, let fileURL = textDocument?.fileURL,
              let textContainer = textView.textContainer
        else {
            hoverPresenter.dismiss()
            return
        }

        let string = textView.string as NSString
        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        if let diagnostic = diagnostics.diagnostic(atUTF16Offset: index, in: string) {
            hoverPresenter.show(diagnostic.message, at: point, in: textView)
            return
        }

        guard let version = LanguageServerPool.shared.trackedVersion(fileURL: fileURL) else {
            hoverPresenter.dismiss()
            return
        }
        let position = LSPPosition(utf16Offset: index, in: string)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let text = await LanguageServerPool.shared.requestHover(fileURL: fileURL, position: position),
                  !Task.isCancelled,
                  LanguageServerPool.shared.trackedVersion(fileURL: fileURL) == version
            else {
                self.hoverPresenter.dismiss()
                return
            }
            self.hoverPresenter.show(text, at: point, in: self.textView)
        }
    }
}
