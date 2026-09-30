import Foundation
import OpenEditConfig

/// The app-facing half of the LSP client (ARCHITECTURE.md component map: LSP
/// client spawns and owns a pool of language server processes). One
/// `LanguageServerClient` per language, shared by every open document of that
/// language; spawn happens only for a server that `LanguageServerLocator`
/// already declared available, so one open event cannot both warn (#7) and
/// launch (#6).
///
/// Document lifecycle entry points are synchronous and safe to call in any
/// order from the document flow, including edits that land while the server
/// is still handshaking: those are buffered per document (full-document sync
/// makes only the latest text matter) and flushed as part of the eventual
/// `didOpen`. A crashed server is simply dropped — already-open documents
/// keep editing with no LSP until they are reopened, when the next open event
/// respawns the process.
@MainActor
public final class LSPProcessPool {
    /// Documents tracked by this pool, keyed by LSP URI.
    private struct PoolDocument {
        let languageID: String
        var version: Int
    }

    private var documents: [String: PoolDocument] = [:]
    private var clients: [String: LanguageServerClient] = [:]
    private var launchTasks: [String: Task<Bool, Never>] = [:]
    private var unlaunchedEdits: [String: String] = [:]

    /// Resolves a file's config entry. The app injects
    /// `DocumentLanguageMapping.resolvedLanguage(for:)`; tests inject fakes.
    private let languageResolver: @MainActor (URL?) -> ResolvedLanguage?

    /// Builds a client (and thus its transport) for a resolved executable.
    private let clientFactory: @MainActor (String) -> LanguageServerClient

    /// Server notifications for consumed features (diagnostics in #6
    /// Checkpoint B). First parameter: the language ID.
    public var onServerNotification: ((String, JSONRPCMessage) -> Void)?

    public var defaultLingerInterval: TimeInterval = 5 * 60

    public init(
        languageResolver: @MainActor @escaping (URL?) -> ResolvedLanguage?,
        clientFactory: @MainActor @escaping (String) -> LanguageServerClient
    ) {
        self.languageResolver = languageResolver
        self.clientFactory = clientFactory
    }

    // MARK: - Document lifecycle

    /// One document-open event. Consults the availability verdict already
    /// computed for this open (`.available` alone spawns); a `.missing` or
    /// highlighting-only language never spawns a process here.
    public func documentOpened(
        fileURL: URL?,
        initialText: String,
        availability: LanguageServerAvailability
    ) {
        guard let fileURL,
              let language = languageResolver(fileURL),
              case let .available(executablePath) = availability
        else { return }

        let uri = FileURI.make(from: fileURL)
        guard let uri, documents[uri] == nil else { return }

        documents[uri] = PoolDocument(languageID: language.languageID, version: 1)
        unlaunchedEdits[uri] = initialText

        Task { [weak self] in
            await self?.openDocument(uri: uri, languageID: language.languageID, executablePath: executablePath)
        }
    }

    /// One document-edit event (user keystroke or a disk reload pushed back in
    /// through `applyText`). Versions are pool-owned and monotonic per URI.
    public func documentEdited(fileURL: URL?, newText: String) {
        guard let fileURL, let uri = FileURI.make(from: fileURL),
              let document = documents[uri]
        else { return }

        var updated = document
        updated.version += 1
        documents[uri] = updated

        if clients[document.languageID]?.isReady == true,
           let client = clients[document.languageID]
        {
            try? client.didChange(uri: uri, version: updated.version, text: newText)
        } else {
            // Server not handshaken yet (or crashed since): buffer the latest
            // text; the next open flush carries it in full.
            unlaunchedEdits[uri] = newText
        }
    }

    /// One document-close event. The shared client starts its linger window
    /// when this removes its last document.
    public func documentClosed(fileURL: URL?) {
        guard let fileURL, let uri = FileURI.make(from: fileURL),
              let document = documents.removeValue(forKey: uri)
        else { return }
        unlaunchedEdits.removeValue(forKey: uri)

        if let client = clients[document.languageID], client.openDocuments[uri] != nil {
            try? client.didClose(uri: uri)
        }
    }

    /// Shut down every live server (app termination).
    public func shutdownAll() async {
        let clients = self.clients
        self.clients.removeAll()
        launchTasks.removeAll()
        for client in clients.values {
            await client.shutdownAndExit()
        }
    }

    // MARK: - Internals

    private func openDocument(uri: String, languageID: String, executablePath: String) async {
        guard let client = await ensureLaunched(languageID: languageID, executablePath: executablePath) else {
            // Launch failed: this document (and any others of the language)
            // stay plain and editable; the next open event retries.
            documents.removeValue(forKey: uri)
            unlaunchedEdits.removeValue(forKey: uri)
            return
        }

        let text = unlaunchedEdits[uri]
        unlaunchedEdits.removeValue(forKey: uri)
        guard let document = documents[uri] else { return }
        try? client.didOpen(
            uri: uri,
            languageID: languageID,
            version: document.version,
            text: text ?? ""
        )
    }

    /// Join a launch already in flight for this language, or start one.
    /// Exactly one launch per client, however many opens race to it.
    private func ensureLaunched(languageID: String, executablePath: String) async -> LanguageServerClient? {
        if let client = clients[languageID] {
            if let task = launchTasks[languageID] {
                _ = await task.value
                return client.isReady ? client : nil
            }
            return client.isReady ? client : nil
        }

        let client = clientFactory(executablePath)
        let languageID_ = languageID
        client.onTerminated = { [weak self] _ in
            self?.clientTerminated(languageID: languageID_)
        }
        client.onServerNotification = { [weak self] message in
            self?.onServerNotification?(languageID_, message)
        }
        clients[languageID] = client

        let task = Task<Bool, Never> { [client] in
            (try? await client.launch()) != nil
        }
        launchTasks[languageID] = task
        let launched = await task.value
        launchTasks[languageID] = nil

        guard launched, client.isReady else {
            clients.removeValue(forKey: languageID)
            return nil
        }
        return client
    }

    private func clientTerminated(languageID: String) {
        // Crashed or died: drop it. Its open documents keep editing without
        // LSP until reopened (recorded in ARCHITECTURE.md 5.5).
        clients.removeValue(forKey: languageID)
        launchTasks.removeValue(forKey: languageID)
    }
}
