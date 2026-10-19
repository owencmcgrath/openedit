import Foundation
import OpenEditConfig

/// One reset row in #8's Settings window (ARCHITECTURE.md 5.6): a language whose
/// missing-LSP notice the user dismissed, plus whether it still has a config
/// entry.
public struct MissingLSPDismissalEntry: Equatable, Sendable {
    /// The stable `languageId` the dismissal is keyed by.
    public let languageID: String

    /// Readable name for the row. The registry carries no display-name field
    /// (5.2), so this is `MissingLSPNotice.displayName(for:)` — the same
    /// capitalization the notice uses, keeping the two consistent.
    public let displayName: String

    /// `false` when the saved dismissal's language no longer resolves in the
    /// current registry (a user file removed or renamed it). Such rows stay
    /// listed rather than being discarded (5.6); the Settings UI labels them.
    public let isConfigured: Bool

    public init(languageID: String, displayName: String, isConfigured: Bool) {
        self.languageID = languageID
        self.displayName = displayName
        self.isConfigured = isConfigured
    }
}

/// Model behind #8's Settings window (ARCHITECTURE.md 5.6). Reads and resets the
/// same per-language persistence keys #7 writes, so the window cannot drift from
/// the notification policy. AppKit-free so the list-building, removed-language,
/// and per-language-reset behavior is unit-testable.
public struct MissingLSPDismissalSettings {
    private let store: MissingLSPSuppressionStore
    private let registry: LanguageRegistry

    public init(
        store: MissingLSPSuppressionStore = MissingLSPSuppressionStore(),
        registry: LanguageRegistry
    ) {
        self.store = store
        self.registry = registry
    }

    /// Every suppressed language, sorted by `languageId`, as displayed rows.
    public func entries() -> [MissingLSPDismissalEntry] {
        store.suppressedLanguageIDs.map { languageID in
            MissingLSPDismissalEntry(
                languageID: languageID,
                displayName: MissingLSPNotice.displayName(for: languageID),
                isConfigured: registry.language(forLanguageID: languageID) != nil
            )
        }
    }

    /// Clear one language's dismissal immediately. Does not post a notice;
    /// eligibility returns on the next new file open (5.6).
    public func reset(languageID: String) {
        store.reset(languageID: languageID)
    }
}
