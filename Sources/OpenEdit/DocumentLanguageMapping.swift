import Foundation
import OpenEditConfig

/// Glue between the config loader and the highlighter (ARCHITECTURE.md 5.2 →
/// 5.4): resolve a file's extension to the grammar name the registry maps it to.
///
/// The registry is loaded once, at first use, from the bundled defaults plus
/// `~/.config/openedit/languages.toml`.
enum DocumentLanguageMapping {
    static let registry: LanguageRegistry = LanguageConfigLoader.load().registry

    /// The grammar name for a file, or `nil` when no config entry claims its
    /// extension (the highlighter then stays inactive and reports why).
    static func grammarName(for fileURL: URL?) -> String? {
        resolvedLanguage(for: fileURL)?.grammar
    }

    /// The full resolved entry for a file, used by the missing-LSP path (5.6)
    /// which needs `binaryName`/`lspPath`/`installCommand`, not just `grammar`.
    static func resolvedLanguage(for fileURL: URL?) -> ResolvedLanguage? {
        guard let fileExtension = fileURL?.pathExtension, !fileExtension.isEmpty else { return nil }
        return registry.language(forExtension: fileExtension)
    }
}
