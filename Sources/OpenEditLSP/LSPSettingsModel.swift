import Foundation
import OpenEditConfig

/// Where a language's server configuration came from (ARCHITECTURE.md 5.14).
public enum LSPSettingsOrigin: Equatable, Sendable {
    /// An explicit `[[language]]` entry shipped in the app's bundled defaults.
    case bundled

    /// An explicit `[[language]]` entry from the user's `languages.toml`.
    case userConfig

    /// A `[[knownServer]]` catalog entry, bundled or user-authored. Both are
    /// autodetected behavior even though a user entry lives in the same file.
    case autodetected
}

/// The outcome shown for one language in the Settings dashboard. Unlike
/// `LanguageServerAvailability`, it also has a state for a saved dismissal whose
/// language no longer resolves (5.6's removed-language rule).
public enum LSPSettingsStatus: Equatable, Sendable {
    /// The server executable was found; the row shows this path.
    case available(executablePath: String)

    /// A server is configured or catalogued but was not found on `PATH`.
    case missing

    /// The language deliberately has no server; the file is highlighting-only.
    case highlightingOnly

    /// A suppressed language that is no longer in the registry. The dismissal is
    /// kept and listed rather than silently discarded (5.6).
    case noLongerConfigured
}

/// One language row in the Settings dashboard (ARCHITECTURE.md 5.14).
public struct LSPSettingsRow: Equatable, Sendable {
    public let languageID: String
    public let displayName: String
    public let extensions: [String]

    /// `nil` only for a stale dismissal whose language no longer resolves.
    public let origin: LSPSettingsOrigin?

    public let status: LSPSettingsStatus

    /// The configured install command, inert text (5.6).
    public let installCommand: String?

    /// The literal `lspPath` override, when one is configured. It is
    /// authoritative over `PATH`, so a miss means that exact path is not
    /// executable (5.2).
    public let lspPath: String?

    /// The binaries that were probed: an explicit `binaryName` or the catalog's
    /// ordered alternatives. Shown when a server is missing so the user can see
    /// what was looked for.
    public let probedBinaries: [String]

    /// The persisted "Don't show again" state. The checkbox is its inverse.
    public var isNotificationSuppressed: Bool

    /// Loader diagnostics attached to this language, when the entry parsed far
    /// enough to carry a `languageId`.
    public let diagnostics: [LanguageConfigDiagnostic]

    public init(
        languageID: String,
        displayName: String,
        extensions: [String],
        origin: LSPSettingsOrigin?,
        status: LSPSettingsStatus,
        installCommand: String?,
        lspPath: String? = nil,
        probedBinaries: [String],
        isNotificationSuppressed: Bool,
        diagnostics: [LanguageConfigDiagnostic] = []
    ) {
        self.languageID = languageID
        self.displayName = displayName
        self.extensions = extensions
        self.origin = origin
        self.status = status
        self.installCommand = installCommand
        self.lspPath = lspPath
        self.probedBinaries = probedBinaries
        self.isNotificationSuppressed = isNotificationSuppressed
        self.diagnostics = diagnostics
    }

    /// Highlighting-only languages never post a missing-server notice, so there
    /// is nothing to toggle. Every other state can (or could in the future) be
    /// missing, including a stale dismissal that must stay resettable.
    public var canToggleNotifications: Bool {
        status != .highlightingOnly
    }

    /// The text the Settings search field matches against. Status and origin
    /// words are included so "missing" or "autodetected" are useful queries.
    public var searchText: String {
        var parts = [displayName, languageID, extensions.joined(separator: " ")]
        if let origin {
            parts.append(origin.searchTerms)
        }
        parts.append(status.searchTerms)
        if let installCommand {
            parts.append(installCommand)
        }
        if let lspPath {
            parts.append(lspPath)
        }
        if !probedBinaries.isEmpty {
            parts.append(probedBinaries.joined(separator: " "))
        }
        if case .available(let executablePath) = status {
            parts.append(executablePath)
        }
        return parts.joined(separator: " ").lowercased()
    }
}

private extension LSPSettingsOrigin {
    var searchTerms: String {
        switch self {
        case .bundled:
            return "bundled default"
        case .userConfig:
            return "your config user languages.toml"
        case .autodetected:
            return "autodetected catalog known server"
        }
    }
}

private extension LSPSettingsStatus {
    var searchTerms: String {
        switch self {
        case .available:
            return "available ready found installed"
        case .missing:
            return "missing not installed"
        case .highlightingOnly:
            return "highlighting only no server"
        case .noLongerConfigured:
            return "no longer configured removed"
        }
    }
}

/// AppKit-free model behind #51's Settings dashboard (ARCHITECTURE.md 5.14).
///
/// Built from one config load, so a window refresh is a fresh load plus a fresh
/// probe. Availability is injected for tests; the default uses the same
/// `LanguageServerLocator` verdict #6 and #7 consume, so the dashboard cannot
/// disagree with an open about whether a server is installed.
public struct LSPSettingsModel {
    private let loadResult: LanguageConfigLoadResult
    private let store: MissingLSPSuppressionStore
    private var allRows: [LSPSettingsRow]

    /// Load the process-wide user config once and build the dashboard. The
    /// window creates a new model on present and on Re-check; open documents keep
    /// their own first-open registry snapshot (5.1).
    public init(
        store: MissingLSPSuppressionStore = MissingLSPSuppressionStore(),
        availability: @escaping (ResolvedLanguage) -> LanguageServerAvailability = {
            LanguageServerLocator.resolve(language: $0)
        }
    ) {
        self.init(
            loadResult: LanguageConfigLoader.load(),
            store: store,
            availability: availability
        )
    }

    /// Designated initializer over an already-loaded config, for tests and for
    /// reusing a snapshot without touching disk.
    public init(
        loadResult: LanguageConfigLoadResult,
        store: MissingLSPSuppressionStore = MissingLSPSuppressionStore(),
        availability: @escaping (ResolvedLanguage) -> LanguageServerAvailability = {
            LanguageServerLocator.resolve(language: $0)
        }
    ) {
        self.loadResult = loadResult
        self.store = store

        let diagnosticsByLanguage: [String: [LanguageConfigDiagnostic]] = {
            var grouped: [String: [LanguageConfigDiagnostic]] = [:]
            for diagnostic in loadResult.diagnostics {
                guard let languageID = diagnostic.languageID else { continue }
                grouped[languageID, default: []].append(diagnostic)
            }
            return grouped
        }()

        var rows = loadResult.registry.languages.map { language in
            LSPSettingsRow(
                languageID: language.languageID,
                displayName: MissingLSPNotice.displayName(for: language.languageID),
                extensions: language.extensions,
                origin: Self.origin(for: language, in: loadResult),
                status: Self.status(for: availability(language)),
                installCommand: language.installCommand,
                lspPath: language.lspPath,
                probedBinaries: language.lspPath == nil ? Self.probedBinaries(for: language) : [],
                isNotificationSuppressed: store.isSuppressed(languageID: language.languageID),
                diagnostics: diagnosticsByLanguage[language.languageID] ?? []
            )
        }

        // Removed languages stay listed (5.6): the saved key is the only record
        // of the user's choice, so the row survives until they reset it.
        let configuredIDs = Set(rows.map(\.languageID))
        for languageID in store.suppressedLanguageIDs where !configuredIDs.contains(languageID) {
            rows.append(
                LSPSettingsRow(
                    languageID: languageID,
                    displayName: MissingLSPNotice.displayName(for: languageID),
                    extensions: [],
                    origin: nil,
                    status: .noLongerConfigured,
                    installCommand: nil,
                    probedBinaries: [],
                    isNotificationSuppressed: true,
                    diagnostics: diagnosticsByLanguage[languageID] ?? []
                )
            )
        }

        rows.sort {
            let left = $0.displayName.lowercased()
            let right = $1.displayName.lowercased()
            return left == right ? $0.languageID < $1.languageID : left < right
        }
        self.allRows = rows
    }

    /// Every loader diagnostic, including file-level ones and entries that were
    /// skipped. The window shows the count and a details list.
    public var allDiagnostics: [LanguageConfigDiagnostic] {
        loadResult.diagnostics
    }

    /// Diagnostics that could not be attached to a row: file-level failures and
    /// invalid entries whose `languageId` never reached the registry.
    public var unattachedDiagnostics: [LanguageConfigDiagnostic] {
        let attachedIDs = Set(allRows.map(\.languageID))
        return loadResult.diagnostics.filter { diagnostic in
            guard let languageID = diagnostic.languageID else { return true }
            return !attachedIDs.contains(languageID)
        }
    }

    /// Rows filtered by the search field. Terms are ANDed, so "python missing"
    /// finds the Python row only when its status matches too.
    public func rows(matching query: String = "") -> [LSPSettingsRow] {
        let terms = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return allRows }

        return allRows.filter { row in
            let searchText = row.searchText
            return terms.allSatisfy { searchText.contains($0) }
        }
    }

    /// Toggle the same per-language key #7's notification action writes: checked
    /// clears the suppression, unchecked persists it (ARCHITECTURE.md 5.6/5.14).
    /// Immediate and per-language; never touches another row.
    public mutating func setNotificationsEnabled(_ enabled: Bool, for languageID: String) {
        guard let index = allRows.firstIndex(where: { $0.languageID == languageID }),
              allRows[index].canToggleNotifications
        else {
            return
        }

        if enabled {
            store.reset(languageID: languageID)
        } else {
            store.suppress(languageID: languageID)
        }

        if enabled, allRows[index].status == .noLongerConfigured {
            // With the stored key gone, a removed language has no reason to
            // stay on the list at all (5.6's row exists only while suppressed).
            allRows.remove(at: index)
        } else {
            allRows[index].isNotificationSuppressed = !enabled
        }
    }

    // MARK: - Row construction

    private static func status(for availability: LanguageServerAvailability) -> LSPSettingsStatus {
        switch availability {
        case .available(let executablePath):
            return .available(executablePath: executablePath)
        case .missing:
            return .missing
        case .highlightingOnly:
            return .highlightingOnly
        }
    }

    private static func origin(
        for language: ResolvedLanguage,
        in loadResult: LanguageConfigLoadResult
    ) -> LSPSettingsOrigin {
        if !language.binaryAlternatives.isEmpty {
            return .autodetected
        }
        if loadResult.userConfiguredLanguageIDs.contains(language.languageID) {
            return .userConfig
        }
        return .bundled
    }

    private static func probedBinaries(for language: ResolvedLanguage) -> [String] {
        if let binaryName = language.binaryName, !binaryName.isEmpty {
            return [binaryName]
        }
        return language.binaryAlternatives
    }
}
