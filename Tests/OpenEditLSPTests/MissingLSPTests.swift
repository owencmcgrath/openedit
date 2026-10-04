import Foundation
import Testing
import OpenEditConfig
@testable import OpenEditLSP

/// A controllable stand-in for `UserNotifications`: records authorization
/// requests and posted notices, and lets a test decide whether permission is
/// granted.
private final class NotificationPresenterSpy: NotificationPresenting {
    var isAuthorized = true
    private(set) var configureCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var postedNotices: [(notice: MissingLSPNotice, languageID: String)] = []

    func configure() {
        configureCount += 1
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        authorizationRequestCount += 1
        completion(isAuthorized)
    }

    func present(notice: MissingLSPNotice, languageID: String) {
        postedNotices.append((notice, languageID))
    }
}

@Suite struct LanguageServerLocatorTests {
    private func language(
        binaryName: String? = "pylsp",
        lspPath: String? = nil
    ) -> ResolvedLanguage {
        ResolvedLanguage(
            languageID: "python",
            extensions: ["py"],
            grammar: "python",
            binaryName: binaryName,
            installCommand: "pip install python-lsp-server",
            lspPath: lspPath
        )
    }

    @Test func findsExecutableOnControlledPath() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: "/usr/bin:/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pylsp" }
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/pylsp"))
    }

    @Test func earlierPathEntryWins() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: "/first:/second",
            isExecutableFile: { $0 == "/first/pylsp" || $0 == "/second/pylsp" }
        )

        #expect(availability == .available(executablePath: "/first/pylsp"))
    }

    @Test func missingBinaryIsReported() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { _ in false }
        )

        #expect(availability == .missing)
    }

    @Test func literalPathIsUsedWhenExecutable() {
        let availability = LanguageServerLocator.resolve(
            language: language(lspPath: "/opt/venv/bin/pylsp"),
            pathEnvironment: "/usr/bin",
            isExecutableFile: { $0 == "/opt/venv/bin/pylsp" }
        )

        #expect(availability == .available(executablePath: "/opt/venv/bin/pylsp"))
    }

    /// A configured literal path is authoritative: an invalid one is a miss
    /// even if a same-named binary exists on PATH.
    @Test func invalidLiteralPathDoesNotFallBackToPath() {
        let availability = LanguageServerLocator.resolve(
            language: language(lspPath: "/missing/pylsp"),
            pathEnvironment: "/usr/bin",
            isExecutableFile: { $0 == "/usr/bin/pylsp" }
        )

        #expect(availability == .missing)
    }

    @Test func highlightingOnlyNeverResolves() {
        let availability = LanguageServerLocator.resolve(
            language: language(binaryName: nil),
            pathEnvironment: "/usr/bin",
            isExecutableFile: { _ in true }
        )

        #expect(availability == .highlightingOnly)
    }

    // MARK: - Catalog autodetection

    private func catalogLanguage(candidates: [String]) -> ResolvedLanguage {
        ResolvedLanguage(
            languageID: "python",
            extensions: ["py"],
            grammar: "python",
            installCommand: "pip install python-lsp-server",
            binaryAlternatives: candidates
        )
    }

    @Test func catalogCandidateProbedInOrderFirstHitWins() {
        let availability = LanguageServerLocator.resolve(
            language: catalogLanguage(candidates: ["pylsp", "pyright-langserver"]),
            pathEnvironment: "/usr/bin:/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pyright-langserver" }
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/pyright-langserver"))
    }

    @Test func catalogLaterCandidateWinsWhenEarlierMissing() {
        let availability = LanguageServerLocator.resolve(
            language: catalogLanguage(candidates: ["pylsp", "pyright-langserver"]),
            pathEnvironment: "/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pyright-langserver" }
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/pyright-langserver"))
    }

    /// All candidates missing is a `.missing` verdict (so #7 posts the catalog's
    /// install command), not `.highlightingOnly`.
    @Test func catalogAllMissingIsMissing() {
        let availability = LanguageServerLocator.resolve(
            language: catalogLanguage(candidates: ["pylsp", "pyright-langserver"]),
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { _ in false }
        )

        #expect(availability == .missing)
    }

    /// Explicit `binaryName` config wins: an available catalog alternative must
    /// not rescue a missing explicit binary.
    @Test func explicitBinaryNameWinsOverCatalogCandidates() {
        let explicit = ResolvedLanguage(
            languageID: "python",
            extensions: ["py"],
            grammar: "python",
            binaryName: "pylsp",
            binaryAlternatives: ["pyright-langserver"]
        )
        let availability = LanguageServerLocator.resolve(
            language: explicit,
            pathEnvironment: "/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pyright-langserver" }
        )

        #expect(availability == .missing)
    }

    /// A catalog language with no grammar (LSP-only) still resolves a server;
    /// grammar absence must not force highlighting-only.
    @Test func catalogLanguageWithoutGrammarStillResolves() {
        let rust = ResolvedLanguage(
            languageID: "rust",
            extensions: ["rs"],
            grammar: nil,
            binaryAlternatives: ["rust-analyzer"]
        )
        let availability = LanguageServerLocator.resolve(
            language: rust,
            pathEnvironment: "/usr/local/bin",
            isExecutableFile: { $0 == "/usr/local/bin/rust-analyzer" }
        )

        #expect(availability == .available(executablePath: "/usr/local/bin/rust-analyzer"))
        #expect(rust.isHighlightingOnly == false)
    }

    /// No `PATH` in the environment must still check the documented fallback
    /// locations, not silently fail.
    @Test func absentPathVariableUsesFallback() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: nil,
            isExecutableFile: { $0 == "/usr/local/bin/pylsp" }
        )

        #expect(availability == .available(executablePath: "/usr/local/bin/pylsp"))
    }
}

@Suite struct WellKnownInstallDirectoryTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    private func language(binaryName: String? = nil, candidates: [String] = []) -> ResolvedLanguage {
        ResolvedLanguage(
            languageID: "go",
            extensions: ["go"],
            grammar: nil,
            binaryName: binaryName,
            binaryAlternatives: candidates
        )
    }

    /// A GUI launch has no `/opt/homebrew/bin` on `PATH`; the well-known list
    /// must still find an Apple Silicon Homebrew install.
    @Test func homebrewAppleSiliconDirectoryProbedWhenPathPresent() {
        let availability = LanguageServerLocator.resolve(
            language: language(binaryName: "gopls"),
            pathEnvironment: "/usr/bin:/bin:/usr/sbin:/sbin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/gopls" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/gopls"))
    }

    /// `~` entries expand against the home directory: rustup's `~/.cargo/bin`
    /// and `go install`'s `~/go/bin`.
    @Test func homeRelativeWellKnownDirectoriesAreExpanded() {
        let rust = ResolvedLanguage(
            languageID: "rust",
            extensions: ["rs"],
            grammar: nil,
            binaryAlternatives: ["rust-analyzer"]
        )
        let availability = LanguageServerLocator.resolve(
            language: rust,
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { $0 == "/Users/test/.cargo/bin/rust-analyzer" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/Users/test/.cargo/bin/rust-analyzer"))
    }

    @Test func goBinIsProbedForCatalogCandidate() {
        let availability = LanguageServerLocator.resolve(
            language: language(candidates: ["gopls"]),
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { $0 == "/Users/test/go/bin/gopls" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/Users/test/go/bin/gopls"))
    }

    /// An explicit `PATH` entry is probed before the well-known directories, so
    /// user shims (pyenv/asdf) keep precedence over brew.
    @Test func pathEntriesPrecedeWellKnownDirectories() {
        let availability = LanguageServerLocator.resolve(
            language: language(binaryName: "gopls"),
            pathEnvironment: "/custom/bin",
            isExecutableFile: { $0 == "/custom/bin/gopls" || $0 == "/opt/homebrew/bin/gopls" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/custom/bin/gopls"))
    }

    /// The search list is `PATH` entries first, then well-known directories,
    /// with a directory already on `PATH` not probed twice.
    @Test func searchDirectoriesOrderAndDeduplication() {
        let directories = LanguageServerLocator.searchDirectories(
            pathEnvironment: "/opt/homebrew/bin:/usr/bin",
            homeDirectory: home
        )

        #expect(directories.prefix(2) == ["/opt/homebrew/bin", "/usr/bin"])
        #expect(directories.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(directories.contains("/Users/test/.cargo/bin"))
        #expect(directories.contains("/Users/test/go/bin"))
        #expect(directories.contains("/Users/test/.local/bin"))
    }
}

@Suite struct MissingLSPNoticeTests {
    @Test func bodyIsExactInstallCommand() {
        let notice = MissingLSPNotice(language: BundledKnownServers.python.asResolvedLanguage)
        #expect(notice.body == "pip install python-lsp-server")
        #expect(notice.title == "Python language server not installed")
    }

    @Test func missingInstallCommandStillDescribesBinary() {
        let language = ResolvedLanguage(
            languageID: "rust",
            extensions: ["rs"],
            grammar: "rust",
            binaryName: "rust-analyzer"
        )
        let notice = MissingLSPNotice(language: language)
        #expect(notice.body.contains("rust-analyzer"))
        #expect(notice.title == "Rust language server not installed")
    }
}

@Suite struct MissingLSPSuppressionStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "MissingLSPSuppressionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func suppressionPersistsAcrossRestart() {
        let defaults = makeDefaults()

        MissingLSPSuppressionStore(defaults: defaults).suppress(languageID: "python")

        // A fresh store over the same defaults represents a relaunch.
        let afterRelaunch = MissingLSPSuppressionStore(defaults: defaults)
        #expect(afterRelaunch.isSuppressed(languageID: "python"))
    }

    @Test func suppressionIsPerLanguage() {
        let store = MissingLSPSuppressionStore(defaults: makeDefaults())
        store.suppress(languageID: "python")

        #expect(store.isSuppressed(languageID: "python"))
        #expect(!store.isSuppressed(languageID: "rust"))
    }

    @Test func resetClearsOnlyOneLanguage() {
        let store = MissingLSPSuppressionStore(defaults: makeDefaults())
        store.suppress(languageID: "python")
        store.suppress(languageID: "rust")

        store.reset(languageID: "python")

        #expect(!store.isSuppressed(languageID: "python"))
        #expect(store.isSuppressed(languageID: "rust"))
    }

    @Test func listsSuppressedLanguageIDs() {
        let store = MissingLSPSuppressionStore(defaults: makeDefaults())
        store.suppress(languageID: "rust")
        store.suppress(languageID: "python")

        #expect(store.suppressedLanguageIDs == ["python", "rust"])
    }
}

@Suite struct MissingLSPDismissalSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "MissingLSPDismissalSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSettings(defaults: UserDefaults) -> MissingLSPDismissalSettings {
        MissingLSPDismissalSettings(
            store: MissingLSPSuppressionStore(defaults: defaults),
            registry: LanguageRegistry(
                languages: BundledKnownServers.all.map(\.asResolvedLanguage) + BundledLanguages.all
            )
        )
    }

    @Test func listsSuppressedLanguagesWithReadableNames() {
        let defaults = makeDefaults()
        let store = MissingLSPSuppressionStore(defaults: defaults)
        store.suppress(languageID: "python")
        store.suppress(languageID: "rust")

        let entries = makeSettings(defaults: defaults).entries()

        #expect(entries.map(\.languageID) == ["python", "rust"])
        #expect(entries.map(\.displayName) == ["Python", "Rust"])
    }

    @Test func resetClearsOnlyOneLanguageAndPersists() {
        let defaults = makeDefaults()
        let store = MissingLSPSuppressionStore(defaults: defaults)
        store.suppress(languageID: "python")
        store.suppress(languageID: "rust")

        // A fresh settings over the same defaults represents the Settings window
        // reopening; reset must persist for the next launch too.
        makeSettings(defaults: defaults).reset(languageID: "python")

        let afterRelaunch = MissingLSPSuppressionStore(defaults: defaults)
        #expect(!afterRelaunch.isSuppressed(languageID: "python"))
        #expect(afterRelaunch.isSuppressed(languageID: "rust"))
    }

    /// A language removed from the registry keeps its dismissal and stays
    /// listed (5.6); a mapping change must not silently discard the choice.
    @Test func removedLanguageStaysListedAndResettable() {
        let defaults = makeDefaults()
        MissingLSPSuppressionStore(defaults: defaults).suppress(languageID: "ruby")

        let settings = makeSettings(defaults: defaults)
        let entries = settings.entries()
        #expect(entries.map(\.languageID) == ["ruby"])
        #expect(entries.first?.isConfigured == false)
        #expect(entries.first?.displayName == "Ruby")

        settings.reset(languageID: "ruby")
        #expect(!MissingLSPSuppressionStore(defaults: defaults).isSuppressed(languageID: "ruby"))
    }

    @Test func configuredLanguageIsMarkedConfigured() {
        let defaults = makeDefaults()
        MissingLSPSuppressionStore(defaults: defaults).suppress(languageID: "python")

        let entry = makeSettings(defaults: defaults).entries().first
        #expect(entry?.isConfigured == true)
    }
}

@Suite struct MissingLSPNotifierTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "MissingLSPNotifierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeNotifier(
        defaults: UserDefaults? = nil,
        presenter: NotificationPresenterSpy = NotificationPresenterSpy()
    ) -> (MissingLSPNotifier, MissingLSPSuppressionStore, NotificationPresenterSpy) {
        let store = MissingLSPSuppressionStore(defaults: defaults ?? makeDefaults())
        let notifier = MissingLSPNotifier(suppressionStore: store, presenter: presenter)
        return (notifier, store, presenter)
    }

    @Test func missingServerPostsNoticeWithExactText() {
        let (notifier, _, presenter) = makeNotifier()

        notifier.handleDocumentOpen(language: BundledKnownServers.python.asResolvedLanguage, availability: .missing)

        #expect(presenter.postedNotices.count == 1)
        #expect(presenter.postedNotices.first?.notice.body == "pip install python-lsp-server")
        #expect(presenter.postedNotices.first?.languageID == "python")
    }

    @Test func availableServerDoesNotNotify() {
        let (notifier, _, presenter) = makeNotifier()

        notifier.handleDocumentOpen(
            language: BundledKnownServers.python.asResolvedLanguage,
            availability: .available(executablePath: "/usr/local/bin/pylsp")
        )

        #expect(presenter.postedNotices.isEmpty)
        #expect(presenter.authorizationRequestCount == 0)
    }

    @Test func highlightingOnlyDoesNotNotify() {
        let (notifier, _, presenter) = makeNotifier()

        notifier.handleDocumentOpen(language: BundledLanguages.json, availability: .highlightingOnly)

        #expect(presenter.postedNotices.isEmpty)
        #expect(presenter.authorizationRequestCount == 0)
    }

    @Test func denyingAuthorizationDoesNotPostAndDoesNotBlock() {
        let presenter = NotificationPresenterSpy()
        presenter.isAuthorized = false
        let (notifier, _, _) = makeNotifier(presenter: presenter)

        notifier.handleDocumentOpen(language: BundledKnownServers.python.asResolvedLanguage, availability: .missing)

        #expect(presenter.authorizationRequestCount == 1)
        #expect(presenter.postedNotices.isEmpty)
    }

    @Test func suppressedLanguageIsNotRequestedOrPosted() {
        let defaults = makeDefaults()
        MissingLSPSuppressionStore(defaults: defaults).suppress(languageID: "python")
        let (notifier, _, presenter) = makeNotifier(defaults: defaults)

        notifier.handleDocumentOpen(language: BundledKnownServers.python.asResolvedLanguage, availability: .missing)

        #expect(presenter.postedNotices.isEmpty)
        #expect(presenter.authorizationRequestCount == 0)
    }

    @Test func suppressOneLanguageLeavesAnotherNotifying() {
        let defaults = makeDefaults()
        MissingLSPSuppressionStore(defaults: defaults).suppress(languageID: "python")
        let rust = ResolvedLanguage(
            languageID: "rust",
            extensions: ["rs"],
            grammar: "rust",
            binaryName: "rust-analyzer",
            installCommand: "rustup component add rust-analyzer"
        )
        let (notifier, _, presenter) = makeNotifier(defaults: defaults)

        notifier.handleDocumentOpen(language: BundledKnownServers.python.asResolvedLanguage, availability: .missing)
        notifier.handleDocumentOpen(language: rust, availability: .missing)

        #expect(presenter.postedNotices.map(\.languageID) == ["rust"])
    }

    /// The "Don't show again" action persists; an ordinary dismissal (the
    /// default action identifier) must not suppress.
    @Test func onlyDontShowAgainActionSuppresses() {
        let (notifier, store, _) = makeNotifier()

        notifier.handleAction(identifier: "com.apple.UNNotificationDefaultActionIdentifier", languageID: "python")
        #expect(!store.isSuppressed(languageID: "python"))

        notifier.handleAction(
            identifier: MissingLSPNotifier.dontShowAgainActionIdentifier,
            languageID: "python"
        )
        #expect(store.isSuppressed(languageID: "python"))
    }

    /// A server installed after a notice was shown (or suppressed) is picked up
    /// on the next open; the now-available result short-circuits the notice.
    @Test func newlyAvailableServerSuppressesNoticeOnNextOpen() {
        let (notifier, store, presenter) = makeNotifier()

        notifier.handleDocumentOpen(language: BundledKnownServers.python.asResolvedLanguage, availability: .missing)
        #expect(presenter.postedNotices.count == 1)

        notifier.handleDocumentOpen(
            language: BundledKnownServers.python.asResolvedLanguage,
            availability: .available(executablePath: "/usr/local/bin/pylsp")
        )
        #expect(presenter.postedNotices.count == 1)
        #expect(!store.isSuppressed(languageID: "python"))
    }

    @Test func startConfiguresAndRequestsAuthorization() {
        let (notifier, _, presenter) = makeNotifier()

        notifier.start()

        #expect(presenter.configureCount == 1)
        #expect(presenter.authorizationRequestCount == 1)
    }

    /// A catalog-only language that is all-missing gets exactly one notice,
    /// tagged with its `languageId` and carrying the catalog's install command,
    /// so #8's dismissal/reset keys work unchanged.
    @Test func catalogMissingServerPostsOneNoticeTaggedWithLanguageID() {
        let (notifier, _, presenter) = makeNotifier()
        let rust = BundledKnownServers.rust.asResolvedLanguage

        notifier.handleDocumentOpen(language: rust, availability: .missing)

        #expect(presenter.postedNotices.count == 1)
        #expect(presenter.postedNotices.first?.languageID == "rust")
        #expect(presenter.postedNotices.first?.notice.body == "rustup component add rust-analyzer")
    }

    /// A discovered catalog server produces no notice.
    @Test func discoveredCatalogServerDoesNotNotify() {
        let (notifier, _, presenter) = makeNotifier()

        notifier.handleDocumentOpen(
            language: BundledKnownServers.rust.asResolvedLanguage,
            availability: .available(executablePath: "/usr/local/bin/rust-analyzer")
        )

        #expect(presenter.postedNotices.isEmpty)
        #expect(presenter.authorizationRequestCount == 0)
    }
}
