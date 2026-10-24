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

/// The install state shown for one language in the Settings inventory.
public enum LSPSettingsStatus: Equatable, Sendable {
    /// The server executable was found; the row shows this path.
    case available(executablePath: String)

    /// A server is configured or catalogued but was not found on `PATH`.
    case missing

    /// The language deliberately has no server; the file is highlighting-only.
    case highlightingOnly
}

/// One language row in the Settings inventory (ARCHITECTURE.md 5.14).
public struct LSPSettingsRow: Equatable, Sendable {
    public let languageID: String
    public let displayName: String
    public let extensions: [String]
    public let origin: LSPSettingsOrigin
    public let status: LSPSettingsStatus

    /// The configured install command, inert text (5.6). The app never runs it.
    public let installCommand: String?

    /// The literal `lspPath` override, when configured. It is authoritative over
    /// `PATH`, so a miss means that exact path is not executable (5.2).
    public let lspPath: String?

    /// The binaries that were probed: an explicit `binaryName` or the catalog's
    /// ordered alternatives. Shown in the tooltip when a server is missing.
    public let probedBinaries: [String]

    /// Loader diagnostics attached to this language, when the entry parsed far
    /// enough to carry a `languageId`.
    public let diagnostics: [LanguageConfigDiagnostic]

    public init(
        languageID: String,
        displayName: String,
        extensions: [String],
        origin: LSPSettingsOrigin,
        status: LSPSettingsStatus,
        installCommand: String?,
        lspPath: String? = nil,
        probedBinaries: [String],
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
        self.diagnostics = diagnostics
    }

    /// Whether the configured `installCommand` is usable text. An absent or
    /// empty command is the "no install command configured" state.
    public var hasInstallCommand: Bool {
        guard let installCommand else { return false }
        return !installCommand.isEmpty
    }

    /// What the row's Copy action puts on the clipboard: the resolved path for
    /// a ready server, the install command for a missing one, nothing otherwise.
    public var copyValue: String? {
        switch status {
        case .available(let executablePath):
            return executablePath
        case .missing:
            return hasInstallCommand ? installCommand : nil
        case .highlightingOnly:
            return nil
        }
    }

    /// A not-installed row with no install command offers Open Config instead of
    /// Copy — the user's only remedy is editing languages.toml.
    public var needsOpenConfigAction: Bool {
        guard case .missing = status else { return false }
        return !hasInstallCommand
    }
}

/// AppKit-free model behind #51's Settings inventory (ARCHITECTURE.md 5.14).
///
/// Built from one config load, so a window refresh is a fresh load plus a fresh
/// probe. Availability is injected for tests; the default uses the same
/// `LanguageServerLocator` verdict #6's process pool consumes, so the inventory
/// cannot disagree with an open about whether a server is installed.
public struct LSPSettingsModel {
    private let loadResult: LanguageConfigLoadResult
    private let allRows: [LSPSettingsRow]

    /// Load the process-wide user config once and build the inventory. The
    /// window creates a new model on present and on Re-check; open documents keep
    /// their own first-open registry snapshot (5.1).
    public init(
        availability: @escaping (ResolvedLanguage) -> LanguageServerAvailability = {
            LanguageServerLocator.resolve(language: $0)
        }
    ) {
        self.init(loadResult: LanguageConfigLoader.load(), availability: availability)
    }

    /// Designated initializer over an already-loaded config, for tests and for
    /// reusing a snapshot without touching disk.
    public init(
        loadResult: LanguageConfigLoadResult,
        availability: @escaping (ResolvedLanguage) -> LanguageServerAvailability = {
            LanguageServerLocator.resolve(language: $0)
        }
    ) {
        self.loadResult = loadResult

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
                displayName: Self.displayName(for: language.languageID),
                extensions: language.extensions,
                origin: Self.origin(for: language, in: loadResult),
                status: Self.status(for: availability(language)),
                installCommand: language.installCommand,
                lspPath: language.lspPath,
                probedBinaries: language.lspPath == nil ? Self.probedBinaries(for: language) : [],
                diagnostics: diagnosticsByLanguage[language.languageID] ?? []
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
    /// skipped. The Configuration tab lists them; the Languages tab shows a
    /// count banner that points here.
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

    /// The inventory rows, sorted by display name.
    public func rows() -> [LSPSettingsRow] {
        allRows
    }

    // MARK: - Row construction

    private static func displayName(for languageID: String) -> String {
        guard let first = languageID.first else { return languageID }
        return first.uppercased() + languageID.dropFirst()
    }

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
