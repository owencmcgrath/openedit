/// Lookup half of the config loader (ARCHITECTURE.md 5.2): the resolved language
/// list plus extension- and ID-keyed indexes for #5/#7. The order of `languages`
/// is meaningful for duplicate extensions — when two entries claim the same
/// extension the later one wins (see `LanguageConfigLoader`).
public struct LanguageRegistry: Sendable {
    public let languages: [ResolvedLanguage]

    private let languagesByExtension: [String: ResolvedLanguage]
    private let languagesByID: [String: ResolvedLanguage]

    public init(languages: [ResolvedLanguage]) {
        self.languages = languages

        var byExtension: [String: ResolvedLanguage] = [:]
        var byID: [String: ResolvedLanguage] = [:]
        for language in languages {
            byID[language.languageID] = language
            for extensionName in language.extensions {
                byExtension[ResolvedLanguage.normalizedExtension(extensionName)] = language
            }
        }
        self.languagesByExtension = byExtension
        self.languagesByID = byID
    }

    /// The language that owns `fileExtension` (which may be written with or
    /// without a leading dot and in any case). Returns `nil` for an unclaimed
    /// extension, which means no highlighting or LSP for that file.
    public func language(forExtension fileExtension: String) -> ResolvedLanguage? {
        languagesByExtension[ResolvedLanguage.normalizedExtension(fileExtension)]
    }

    public func language(forLanguageID languageID: String) -> ResolvedLanguage? {
        languagesByID[languageID]
    }
}
