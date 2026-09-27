import AppKit

final class DocumentWindowController: NSWindowController {
    let fileURL: URL?

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let lineNumberRuler: LineNumberRulerView

    init(fileURL: URL?) {
        self.fileURL = fileURL

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        textView = EditorTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        lineNumberRuler = LineNumberRulerView(textView: textView, scrollView: scrollView)
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
        window.title = fileURL?.lastPathComponent ?? "Untitled"

        super.init(window: window)

        loadContents()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
    }

    private func loadContents() {
        guard let fileURL else { return }

        let contents = (try? String(contentsOf: fileURL, encoding: .utf8))
            ?? (try? String(contentsOf: fileURL, encoding: .isoLatin1))

        if let contents {
            textView.string = contents
            textView.undoManager?.removeAllActions()
        }
    }
}
