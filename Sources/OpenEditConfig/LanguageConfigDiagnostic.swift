import Foundation

/// A single problem found while loading the user config (ARCHITECTURE.md 5.2).
/// Carries the config path and, when the problem is scoped to an entry and/or
/// field, those too, so a caller can point the user at the exact line they need
/// to fix. An entry that produces a diagnostic is skipped, never silently
/// applied.
public struct LanguageConfigDiagnostic: Equatable, Sendable {
    public let configPath: String

    /// Zero-based index into the `[[language]]` array, when the problem belongs
    /// to a specific entry.
    public let entryIndex: Int?

    /// The entry's `languageId`, when it parsed far enough to read one.
    public let languageID: String?

    /// The offending field name, when the problem belongs to one.
    public let field: String?

    public let message: String

    public init(
        configPath: String,
        entryIndex: Int? = nil,
        languageID: String? = nil,
        field: String? = nil,
        message: String
    ) {
        self.configPath = configPath
        self.entryIndex = entryIndex
        self.languageID = languageID
        self.field = field
        self.message = message
    }

    /// Human-readable one-liner, e.g.
    /// `~/.config/openedit/languages.toml: [[language]][2] (python).binaryName: expected a string`.
    public var description: String {
        var location = configPath
        if let entryIndex {
            location += ": [[language]][\(entryIndex)]"
        }
        if let languageID {
            location += " (\(languageID))"
        }
        if let field {
            location += ".\(field)"
        }
        return "\(location): \(message)"
    }
}

/// The output of loading the config (ARCHITECTURE.md 5.2): the merged registry
/// plus any diagnostics. A loader never throws out of a bad config — the app
/// keeps the bundled defaults and surfaces the diagnostics instead.
public struct LanguageConfigLoadResult {
    public let registry: LanguageRegistry
    public let diagnostics: [LanguageConfigDiagnostic]

    public init(registry: LanguageRegistry, diagnostics: [LanguageConfigDiagnostic]) {
        self.registry = registry
        self.diagnostics = diagnostics
    }
}
