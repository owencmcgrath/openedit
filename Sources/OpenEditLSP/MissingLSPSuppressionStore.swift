import Foundation

/// Persists #7's per-language "Don't show again" choice (ARCHITECTURE.md 5.6).
///
/// One boolean per stable `languageId`, so dismissing the Python notice never
/// silences another language. #8's Settings window reads and resets these same
/// keys via `suppressedLanguageIDs` / `reset(languageID:)`; the key format is
/// therefore part of the seam, not a private detail.
public struct MissingLSPSuppressionStore {
    /// `missingLSP.suppressed.<languageId> = true`. Documented here because #8
    /// shares it.
    public static let keyPrefix = "missingLSP.suppressed."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(for languageID: String) -> String {
        keyPrefix + languageID
    }

    public func isSuppressed(languageID: String) -> Bool {
        defaults.bool(forKey: Self.key(for: languageID))
    }

    public func suppress(languageID: String) {
        defaults.set(true, forKey: Self.key(for: languageID))
    }

    /// Clears the flag immediately (#8). Does not post a notice; eligibility
    /// returns on the next new file open.
    public func reset(languageID: String) {
        defaults.removeObject(forKey: Self.key(for: languageID))
    }

    /// Every suppressed `languageId`, for #8's Settings list. Reads the
    /// persisted dictionary rather than a separate index so state cannot drift.
    public var suppressedLanguageIDs: [String] {
        let prefix = Self.keyPrefix
        return defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .filter { defaults.bool(forKey: $0) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }
}
