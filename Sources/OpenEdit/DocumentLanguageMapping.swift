import Foundation
import OpenEditConfig
import OpenEditHighlighting
import OpenEditWindowing

/// Glue between the config loader and the highlighter (ARCHITECTURE.md 5.2 →
/// 5.4): resolve a file's extension to the grammar name the registry maps it to.
///
/// The process-wide registry is loaded once, at first use, from the bundled
/// defaults plus `~/.config/openedit/languages.toml`. A CLI open can override
/// that per document (`--config`, `--no-config`, `--force-language`), so the
/// per-open options are threaded through the lookup instead of relying only on
/// the shared instance.
enum DocumentLanguageMapping {
    static let registry: LanguageRegistry = LanguageConfigLoader.load().registry

    /// Loaded registries keyed by config path, plus the bundled-only registry.
    /// A CLI document snapshot outlives the open; keeping the parsed registry
    /// avoids re-reading TOML for every document window.
    private static var registryCache: [String: LanguageRegistry] = [:]

    static func registry(for options: OpenDocumentOptions) -> LanguageRegistry {
        if options.usesBundledConfigOnly {
            return cachedRegistry(key: "bundled") {
                LanguageConfigLoader.load(userConfigAt: nil).registry
            }
        }
        if let configPath = options.configPath, !configPath.isEmpty {
            return cachedRegistry(key: configPath) {
                LanguageConfigLoader.load(
                    userConfigAt: URL(fileURLWithPath: configPath)
                ).registry
            }
        }
        return registry
    }

    private static func cachedRegistry(
        key: String,
        load: () -> LanguageRegistry
    ) -> LanguageRegistry {
        if let cached = registryCache[key] {
            return cached
        }
        let loaded = load()
        registryCache[key] = loaded
        return loaded
    }

    /// The grammar name for a file, or `nil` when no config entry claims its
    /// extension (the highlighter then stays inactive and reports why).
    static func grammarName(
        for fileURL: URL?,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) -> String? {
        guard options.highlighting else { return nil }
        return resolvedLanguage(for: fileURL, options: options)?.grammar
    }

    /// The full resolved entry for a file, used by the language-server path (5.6)
    /// which needs `binaryName`/`lspPath`/`installCommand`, not just `grammar`.
    ///
    /// CLI overrides are applied to a copy of the registry entry, so one
    /// document's `--force-language`/`--no-autodetect` never mutates the shared
    /// registry or another open document.
    static func resolvedLanguage(
        for fileURL: URL?,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) -> ResolvedLanguage? {
        let registry = registry(for: options)
        var language: ResolvedLanguage?

        if let forcedLanguage = options.forcedLanguage, !forcedLanguage.isEmpty {
            language = registry.language(forLanguageID: forcedLanguage)
                ?? ResolvedLanguage(
                    languageID: forcedLanguage,
                    extensions: [],
                    grammar: GrammarRegistry.bundledGrammarNames.contains(forcedLanguage)
                        ? forcedLanguage
                        : nil
                )
        } else if let fileExtension = fileURL?.pathExtension, !fileExtension.isEmpty {
            language = registry.language(forExtension: fileExtension)
        }

        guard var resolved = language else { return nil }
        if !options.highlighting {
            resolved = copy(resolved, grammar: nil)
        }
        if !options.autodetectServers {
            resolved = copy(resolved, grammar: resolved.grammar, binaryAlternatives: [])
        }
        if let lspPath = options.lspServerOverrides[resolved.languageID] {
            resolved = copy(
                resolved,
                grammar: resolved.grammar,
                binaryName: URL(fileURLWithPath: lspPath).lastPathComponent,
                lspPath: lspPath
            )
        }
        return resolved
    }

    /// The language used for LSP wiring. Usually the same as the highlighting
    /// language, but `--lsp-language` can point the server at a different
    /// config entry than the grammar (ARCHITECTURE.md 5.1).
    static func lspLanguage(
        for fileURL: URL?,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) -> ResolvedLanguage? {
        guard let overrideID = options.lspLanguage, !overrideID.isEmpty else {
            return resolvedLanguage(for: fileURL, options: options)
        }
        let registry = registry(for: options)
        var language = registry.language(forLanguageID: overrideID)
            ?? ResolvedLanguage(languageID: overrideID, extensions: [])
        if !options.autodetectServers {
            language = copy(language, grammar: language.grammar, binaryAlternatives: [])
        }
        if let lspPath = options.lspServerOverrides[overrideID] {
            language = copy(
                language,
                grammar: language.grammar,
                binaryName: URL(fileURLWithPath: lspPath).lastPathComponent,
                lspPath: lspPath
            )
        }
        return language
    }

    private static func copy(
        _ language: ResolvedLanguage,
        grammar: String?,
        binaryName: String? = nil,
        lspPath: String? = nil,
        binaryAlternatives: [String]? = nil
    ) -> ResolvedLanguage {
        ResolvedLanguage(
            languageID: language.languageID,
            extensions: language.extensions,
            grammar: grammar,
            binaryName: binaryName ?? language.binaryName,
            installCommand: language.installCommand,
            lspPath: lspPath ?? language.lspPath,
            binaryAlternatives: binaryAlternatives ?? language.binaryAlternatives
        )
    }
}
