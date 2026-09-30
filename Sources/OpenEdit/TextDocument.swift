import AppKit
import Foundation
import OpenEditLSP

/// Identity snapshot of a file on disk, used to coalesce watcher events for a
/// single write (including the echo of this document's own save) into one
/// handling pass. The inode matters because editors often save atomically,
/// leaving the same path pointing at a new file.
struct FileStat: Equatable {
    let inode: UInt64
    let size: UInt64
    let modificationDate: Date

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (attributes[FileAttributeKey(rawValue: "NSFileSystemFileNumber")] as? NSNumber)?.uint64Value,
              let size = (attributes[FileAttributeKey(rawValue: "NSFileSize")] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[FileAttributeKey(rawValue: "NSFileModificationDate")] as? Date
        else { return nil }
        self.inode = inode
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// One open file, as an NSDocument (ARCHITECTURE.md component map). Owns the
/// on-disk round trip, the standard change-count dirty state, and the file
/// watcher that drives silent reload / conflict prompt (5.3). Saving is
/// explicit only (5.11): `autosavesInPlace` keeps its default `false`, so
/// edits reach disk exactly when the user hits Cmd-S — keeping the
/// "did the file change under me" question unambiguous.
final class TextDocument: NSDocument {
    static let fileTypeIdentifier = "public.plain-text"

    private(set) var text: String = ""

    /// True for Untitled documents created by the launch machinery (AppKit's
    /// untitled-at-launch pass and the bare-executable fallbacks all route
    /// through `openUntitledDocumentAndDisplay`, which flags the result in
    /// OpenEditDocumentController). Such a document is a launch artifact, so
    /// when the launch also delivers real file documents the empty ones are
    /// dropped (see settleLaunchedUntitledDocuments) — without any timing
    /// guess about when Apple Events land.
    var wasLaunchedUntitled = false

    private var watcher: FileChangeWatcher?
    private var lastKnownFileStat: FileStat?

    /// The app only ever reads and writes plain text; set the type directly so
    /// NSDocument's save machinery has a writable type without consulting an
    /// Info.plist type table (which the bare `swift run` executable lacks).
    convenience init(fileAt url: URL) throws {
        self.init()
        fileURL = url
        fileType = Self.fileTypeIdentifier
        let data = try Data(contentsOf: url)
        try read(from: data, ofType: Self.fileTypeIdentifier)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let newText = Self.decode(data) else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSLocalizedDescriptionKey: "File is not decodable as text (tried UTF-8 and ISO Latin-1)."]
            )
        }
        text = newText
        refreshWatchState()
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
        startLanguageServerFlow()
    }

    /// One document-open event for the language-server side (ARCHITECTURE.md
    /// 5.5/5.6): resolve the config entry and the server's availability once,
    /// hand the single verdict to both the missing-LSP notice (#7) and the
    /// process pool (#6), so one open cannot both warn and launch.
    private func startLanguageServerFlow() {
        guard let fileURL,
              let language = DocumentLanguageMapping.resolvedLanguage(for: fileURL)
        else { return }

        let availability = LanguageServerLocator.resolve(language: language)
        MissingLSPServerNotification.shared.handleDocumentOpen(
            language: language,
            availability: availability
        )
        LanguageServerPool.shared.documentOpened(
            fileURL: fileURL,
            initialText: text,
            availability: availability
        )
    }

    override func writeSafely(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) throws {
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        // The save itself is an external-looking write; re-snapshot and re-arm
        // here so the watcher callback (delivered asynchronously on the main
        // queue) sees the new stat and swallows it.
        refreshWatchState()
    }

    override func close() {
        watcher?.stop()
        LanguageServerPool.shared.documentClosed(fileURL: fileURL)
        super.close()
    }

    // MARK: - Text flow with the window controller

    /// Called by the window controller after each user edit: mirrors the text
    /// into the document and bumps the standard change count (dirty state).
    func noteTextEdited(_ newText: String) {
        text = newText
        updateChangeCount(.changeDone)
        LanguageServerPool.shared.documentEdited(fileURL: fileURL, newText: newText)
    }

    /// Programmatic text application (initial load, silent reload, reload
    /// chosen from the conflict prompt): mirrors disk content into the
    /// document and its windows without marking the document dirty.
    func applyText(_ newText: String) {
        text = newText
        for controller in windowControllers.compactMap({ $0 as? DocumentWindowController }) {
            controller.applyText(newText)
        }
        updateChangeCount(.changeCleared)
        // A reload changes the server's view of the file just like an edit;
        // full-document sync makes it one didChange.
        LanguageServerPool.shared.documentEdited(fileURL: fileURL, newText: newText)
    }

    // MARK: - External changes (ARCHITECTURE.md 5.3)

    private func externalFileChanged() {
        guard let fileURL, let currentStat = FileStat(url: fileURL) else { return }
        // An external delete has no reload to offer in v1; leave the document
        // holding its text. A later explicit save to the same path re-arms the
        // watcher via refreshWatchState().
        guard currentStat != lastKnownFileStat else { return }

        if isDocumentEdited {
            // Record the file's state only once the prompt is actually
            // scheduled. When the prompt is suppressed (a sheet is already
            // up), the stats stay stale, so the event for the suppressed
            // write is "unseen" and the next post-sheet event re-prompts.
            // The same staleness keeps NSDocument's own save-time conflict
            // check armed for a change the user was never asked about.
            guard promptReloadFromDisk() else { return }
            lastKnownFileStat = currentStat
            fileModificationDate = currentStat.modificationDate
        } else {
            // Clean reload: refreshWatchState() inside reloadFromDisk()
            // re-snapshots both stats for us.
            try? reloadFromDisk()
        }
    }

    /// Present the Keep Mine / Reload prompt; returns whether a prompt was
    /// actually scheduled (no window, or a sheet is already attached — a
    /// second external write landing while the prompt is up).
    @discardableResult
    private func promptReloadFromDisk() -> Bool {
        guard let window = windowControllers.lazy.compactMap(\.window).first,
              window.attachedSheet == nil
        else { return false }

        let alert = NSAlert()
        alert.messageText = "File changed on disk"
        alert.informativeText = """
            \(fileURL?.lastPathComponent ?? "Untitled") has changed on disk. Keep \
            your unsaved changes, or reload the file from disk and lose them?
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Reload from Disk")

        var didHandleResponse = false
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, !didHandleResponse else { return }
            didHandleResponse = true
            // Normally AppKit ends the sheet itself; an accessibility-driven
            // button click (how agents drive this app) can complete the modal
            // session without detaching the sheet window, which would block
            // every later prompt and keystroke routed to the window. Ending it
            // again is a no-op when already detached — but AppKit may deliver
            // this completion a second time for that explicit end, so reload
            // exactly once via the guard above.
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: response)
            }
            guard response == .alertSecondButtonReturn else { return }
            try? self.reloadFromDisk()
        }
        return true
    }

    private func reloadFromDisk() throws {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let newText = Self.decode(data)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        applyText(newText)
        refreshWatchState()
    }

    /// Snapshot the file's current stat as "already handled" so the watcher
    /// callback can swallow duplicate events for one write (including the echo
    /// of this document's own save), and (re)arm the watch — an atomic replace
    /// leaves the previous DispatchSource pointed at an unlinked inode.
    private func refreshWatchState() {
        guard let fileURL else { return }
        lastKnownFileStat = FileStat(url: fileURL)
        // Keep NSDocument's save-time conflict check in lockstep with what
        // this document has already seen, including the load itself (the
        // manual `swift run` path bypasses the URL-read machinery that would
        // normally stamp this).
        fileModificationDate = lastKnownFileStat?.modificationDate
        if watcher == nil {
            watcher = FileChangeWatcher(path: fileURL.path) { [weak self] in
                self?.externalFileChanged()
            }
        }
        watcher?.start()
    }

    // MARK: - Decoding

    /// Drop launch-created empty Untitled documents once real file documents
    /// have arrived (the launch artifact vs. user content distinction is the
    /// `wasLaunchedUntitled` flag; edited and non-empty untitled documents are
    /// always kept). Deterministic replacement for the old launch-settle
    /// timer: it runs when a real file document actually opens, however late
    /// that happens.
    static func settleLaunchedUntitledDocuments() {
        for document in NSDocumentController.shared.documents {
            guard let textDocument = document as? TextDocument,
                  textDocument.wasLaunchedUntitled,
                  textDocument.fileURL == nil,
                  !textDocument.isDocumentEdited
            else { continue }
            textDocument.wasLaunchedUntitled = false
            textDocument.close()
        }
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
