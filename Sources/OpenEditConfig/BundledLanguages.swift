/// `[[language]]` entries bundled with the app (ARCHITECTURE.md 5.2): explicit
/// mappings with a grammar but no server — the starting registry when no user
/// file exists, and the base a user file overrides/extends.
///
/// Languages whose server should be *autodetected* live in
/// `BundledKnownServers` instead: an explicit `[[language]]` entry (even one
/// with no `binaryName`) suppresses autodetection for its `languageId`, so a
/// catalog-served language like python has no language entry here. The registry
/// merges both sources (see `LanguageConfigLoader`).
///
/// The grammar names below are verified for highlighting as of #5; see
/// `AGENTS/GRAMMARS.md`.
public enum BundledLanguages {
    public static let all: [ResolvedLanguage] = [
        json,
        markdown,
        toml,
        yaml
    ]

    /// Highlighting-only: no `binaryName`, so no LSP (5.2).
    public static let json = ResolvedLanguage(
        languageID: "json",
        extensions: ["json"],
        grammar: "json"
    )

    /// Highlighting-only.
    public static let markdown = ResolvedLanguage(
        languageID: "markdown",
        extensions: ["md", "markdown"],
        grammar: "markdown"
    )

    /// Highlighting-only.
    public static let toml = ResolvedLanguage(
        languageID: "toml",
        extensions: ["toml"],
        grammar: "toml"
    )

    /// Highlighting-only.
    public static let yaml = ResolvedLanguage(
        languageID: "yaml",
        extensions: ["yaml", "yml"],
        grammar: "yaml"
    )
}
