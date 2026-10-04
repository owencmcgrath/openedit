import Foundation

/// One resolved extension → grammar → language-server mapping (ARCHITECTURE.md
/// 5.2). The same shape represents a bundled default and a user entry, so lookup
/// does not care where a language came from once the loader has merged them.
public struct ResolvedLanguage: Equatable, Sendable {
    /// Stable identity used for override matching in the user file: a user entry
    /// with the same `languageID` replaces the bundled entry wholesale rather
    /// than merging field-by-field.
    public let languageID: String

    /// Lowercase, leading-dot-stripped extensions (e.g. `"py"`, not `".py"`).
    /// Normalized by the loader so lookup and duplicate detection compare equal
    /// spellings the same way.
    public let extensions: [String]

    /// Tree-sitter grammar name, or `nil` when the language has no bundled
    /// grammar. `nil` leaves the text plain and editable; it does not by itself
    /// mean no LSP — a catalog-only language can be LSP-only (`5.2`).
    public let grammar: String?

    /// Executable checked against `PATH` (or `lspPath`) to detect a language
    /// server. Explicit config: when present it wins over `binaryAlternatives`.
    /// Absent alongside empty `binaryAlternatives` means highlighting-only, no
    /// LSP for this language (5.2).
    public let binaryName: String?

    /// Human-readable command shown in the missing-LSP notification (5.6).
    /// Inert text — the app never runs it.
    public let installCommand: String?

    /// Literal path that overrides the `PATH` lookup, for language servers
    /// installed outside `PATH`. Only meaningful alongside `binaryName`.
    public let lspPath: String?

    /// Ordered candidate binary names from the `[[knownServer]]` catalog, probed
    /// on `PATH` in order when there is no explicit `binaryName`/`lspPath`
    /// (ARCHITECTURE.md 5.2/5.6). Empty for an explicit `[[language]]` entry,
    /// which is what makes "do not autodetect here" expressible as a language
    /// entry with no `binaryName`.
    public let binaryAlternatives: [String]

    public init(
        languageID: String,
        extensions: [String],
        grammar: String? = nil,
        binaryName: String? = nil,
        installCommand: String? = nil,
        lspPath: String? = nil,
        binaryAlternatives: [String] = []
    ) {
        self.languageID = languageID
        self.extensions = extensions
        self.grammar = grammar
        self.binaryName = binaryName
        self.installCommand = installCommand
        self.lspPath = lspPath
        self.binaryAlternatives = binaryAlternatives
    }

    /// A language with no explicit `binaryName` and no catalog candidates has
    /// no LSP wiring (ARCHITECTURE.md 5.2). A catalog-only language has
    /// alternatives and is *not* highlighting-only even without a grammar.
    public var isHighlightingOnly: Bool {
        binaryName == nil && binaryAlternatives.isEmpty
    }

    /// Canonical form of a file extension or config spelling: trimmed,
    /// lowercased, and without any leading dot. `" .PY "` and `"py"` both become
    /// `"py"`.
    public static func normalizedExtension(_ rawExtension: String) -> String {
        var extensionName = rawExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while extensionName.hasPrefix(".") {
            extensionName.removeFirst()
        }
        return extensionName
    }
}
