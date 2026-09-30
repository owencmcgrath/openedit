/// Languages bundled with the app (ARCHITECTURE.md 5.2). These are the starting
/// registry when no user file exists, and the base a user file overrides/extends.
///
/// The grammar names and `binaryName`s below are *names*, not verified-working
/// claims: nothing in v1 exercises them yet (#5 highlighting, #7 LSP detection).
/// See the inventory table in ARCHITECTURE.md 5.2 for current status.
public enum BundledLanguages {
    public static let all: [ResolvedLanguage] = [
        python,
        json,
        markdown,
        toml,
        yaml
    ]

    public static let python = ResolvedLanguage(
        languageID: "python",
        extensions: ["py", "pyw"],
        grammar: "python",
        binaryName: "pylsp",
        installCommand: "pip install python-lsp-server"
    )

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
