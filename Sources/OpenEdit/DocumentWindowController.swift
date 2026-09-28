import AppKit

/// Window for one open document: the text view, scroll view, and gutter, with
/// user edits forwarded to the TextDocument for standard NSDocument dirty
/// tracking (ARCHITECTURE.md 5.11) and reloads pushed back in from the
/// document's watcher (5.3).
final class DocumentWindowController: NSWindowController, NSTextViewDelegate {
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let lineNumberRuler: LineNumberRulerView

    /// Guard so programmatic text application (initial load, silent reload,
    /// reload from the conflict prompt) is not counted as a user edit.
    private var isApplyingDocumentText = false

    var textDocument: TextDocument? {
        document as? TextDocument
    }

    init(document: TextDocument) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
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

        super.init(window: window)

        editorTextView.string = document.text
        editorTextView.undoManager?.removeAllActions()
        editorTextView.delegate = self
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
        defer { isApplyingDocumentText = false }
        textView.string = newText
        textView.undoManager?.removeAllActions()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingDocumentText, let textDocument else { return }
        textDocument.noteTextEdited(textView.string)
    }
}
