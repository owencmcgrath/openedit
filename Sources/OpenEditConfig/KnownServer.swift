/// A bundled, user-editable catalog entry describing how to *autodetect* a
/// language server for a language that has no explicit `[[language]]` entry
/// (ARCHITECTURE.md 5.2/5.6).
///
/// This is data, like `BundledLanguages` — the locator's logic stays free of it
/// so tests can inject fakes. The catalog is the source of truth for the
/// ordered candidate list probed on `PATH`; explicit `binaryName`/`lspPath`
/// config always wins and autodetection only fills the gap where config
/// designates no server.
///
/// `grammar` is optional: a catalog-only language with no bundled tree-sitter
/// grammar is still reachable (its extensions map here) and becomes LSP-only,
/// opening as plain, editable text — the inverse of highlighting-only.
public struct KnownServer: Equatable, Sendable {
    /// Stable identity used for override matching in the user file, mirroring
    /// `ResolvedLanguage.languageID`.
    public let languageID: String

    /// Lowercase, leading-dot-stripped extensions. A catalog entry must declare
    /// at least one: discovery is keyed by real file extensions, so an entry
    /// without any is unreachable and is rejected by the loader.
    public let extensions: [String]

    /// Tree-sitter grammar name, or `nil` when no bundled grammar exists for
    /// this language. `nil` means LSP-only, plain-text editing.
    public let grammar: String?

    /// Ordered candidate binary names: probed on `PATH` in order, first
    /// executable wins (ARCHITECTURE.md 5.6).
    public let candidates: [String]

    /// Human-readable command shown in the missing-LSP notice. Inert text — the
    /// app never runs it.
    public let installCommand: String?

    public init(
        languageID: String,
        extensions: [String],
        grammar: String? = nil,
        candidates: [String],
        installCommand: String? = nil
    ) {
        self.languageID = languageID
        self.extensions = extensions
        self.grammar = grammar
        self.candidates = candidates
        self.installCommand = installCommand
    }

    /// The registry shape for an autodetected language: no explicit
    /// `binaryName`/`lspPath`, with the catalog's candidates as the ordered
    /// `binaryAlternatives` the locator probes.
    public var asResolvedLanguage: ResolvedLanguage {
        ResolvedLanguage(
            languageID: languageID,
            extensions: extensions,
            grammar: grammar,
            installCommand: installCommand,
            binaryAlternatives: candidates
        )
    }
}

/// Known language servers bundled with the app (ARCHITECTURE.md 5.2). These are
/// probed on the process's effective `PATH` for languages no `[[language]]`
/// entry claims; they are names, not verified-working claims, until a test or
/// manual check proves them.
public enum BundledKnownServers {
    public static let all: [KnownServer] = [
        python,
        rust,
        go,
        lua
    ]

    /// Python bundles a grammar, so autodetection here highlights *and* serves.
    /// Explicit config wins: a `[[language]]` entry for python (with or without
    /// a server) suppresses this catalog entry entirely (5.2).
    public static let python = KnownServer(
        languageID: "python",
        extensions: ["py", "pyw"],
        grammar: "python",
        candidates: ["pylsp", "pyright-langserver"],
        installCommand: "pip install python-lsp-server"
    )

    /// No bundled grammar: LSP-only, plain-text editing (5.2).
    public static let rust = KnownServer(
        languageID: "rust",
        extensions: ["rs"],
        candidates: ["rust-analyzer"],
        installCommand: "rustup component add rust-analyzer"
    )

    /// No bundled grammar: LSP-only, plain-text editing (5.2).
    public static let go = KnownServer(
        languageID: "go",
        extensions: ["go"],
        candidates: ["gopls"],
        installCommand: "go install golang.org/x/tools/gopls@latest"
    )

    /// No bundled grammar: LSP-only, plain-text editing (5.2).
    public static let lua = KnownServer(
        languageID: "lua",
        extensions: ["lua"],
        candidates: ["lua-language-server"],
        installCommand: "brew install lua-language-server"
    )
}
