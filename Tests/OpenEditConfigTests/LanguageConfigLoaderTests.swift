import Foundation
import Testing

@testable import OpenEditConfig

@Suite struct LanguageConfigLoaderTests {

    // MARK: - Helpers

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private func loadFixture(_ name: String) -> LanguageConfigLoadResult {
        LanguageConfigLoader.load(userConfigAt: fixturesDirectory.appendingPathComponent(name))
    }

    /// The registry a missing/empty user file yields: the catalog-only
    /// languages (autodetected, prepended) followed by the explicit bundled
    /// `[[language]]` entries.
    private var bundledResolved: [ResolvedLanguage] {
        BundledKnownServers.all.map(\.asResolvedLanguage) + BundledLanguages.all
    }

    private func loadInline(
        _ toml: String,
        bundledDefaults: [ResolvedLanguage] = BundledLanguages.all,
        bundledKnownServers: [KnownServer] = BundledKnownServers.all
    ) -> LanguageConfigLoadResult {
        LanguageConfigLoader.load(
            userConfigContents: toml,
            configPath: "/tmp/languages.toml",
            bundledDefaults: bundledDefaults,
            bundledKnownServers: bundledKnownServers
        )
    }

    // MARK: - Missing file / bundled defaults

    @Test func missingFileUsesBundledDefaultsWithoutDiagnostics() {
        let result = LanguageConfigLoader.load(
            userConfigAt: fixturesDirectory.appendingPathComponent("does-not-exist.toml")
        )

        #expect(result.diagnostics.isEmpty)
        #expect(result.registry.languages == bundledResolved)
        #expect(result.registry.language(forExtension: "py")?.languageID == "python")
    }

    @Test func emptyOverlayKeepsBundledDefaults() {
        let result = loadInline("# nothing but comments\n")

        #expect(result.diagnostics.isEmpty)
        #expect(result.registry.languages == bundledResolved)
    }

    @Test func bundledLookupByExtensionNormalizesDotAndCase() {
        let registry = loadInline("").registry

        #expect(registry.language(forExtension: "py")?.languageID == "python")
        #expect(registry.language(forExtension: ".PY")?.languageID == "python")
        #expect(registry.language(forExtension: ".md")?.languageID == "markdown")
        #expect(registry.language(forExtension: "YML")?.languageID == "yaml")
        #expect(registry.language(forExtension: "no-such-extension") == nil)
    }

    @Test func bundledInventory() {
        let languagesByID = Dictionary(uniqueKeysWithValues: BundledLanguages.all.map { ($0.languageID, $0) })
        #expect(Set(languagesByID.keys) == ["json", "markdown", "toml", "yaml"])
        #expect(languagesByID["markdown"]?.extensions == ["md", "markdown"])
        #expect(languagesByID["yaml"]?.extensions == ["yaml", "yml"])
        for highlightingOnlyID in ["json", "markdown", "toml", "yaml"] {
            #expect(languagesByID[highlightingOnlyID]?.isHighlightingOnly == true, "\(highlightingOnlyID)")
        }

        let serversByID = Dictionary(uniqueKeysWithValues: BundledKnownServers.all.map { ($0.languageID, $0) })
        #expect(Set(serversByID.keys) == ["python", "rust", "go", "lua"])
        #expect(serversByID["python"]?.extensions == ["py", "pyw"])
        #expect(serversByID["python"]?.grammar == "python")
        #expect(serversByID["python"]?.candidates == ["pylsp", "pyright-langserver"])
        // No bundled grammar: rust/go/lua are LSP-only, plain text.
        #expect(serversByID["rust"]?.grammar == nil)
        #expect(serversByID["go"]?.grammar == nil)
        #expect(serversByID["lua"]?.grammar == nil)

        // The merged registry exposes catalog languages as non-highlighting-only.
        let registry = LanguageConfigLoader.load(userConfigAt: nil).registry
        #expect(registry.language(forLanguageID: "python")?.isHighlightingOnly == false)
        #expect(registry.language(forLanguageID: "python")?.binaryName == nil)
        #expect(registry.language(forLanguageID: "python")?.binaryAlternatives == ["pylsp", "pyright-langserver"])
        #expect(registry.language(forExtension: "rs")?.languageID == "rust")
        #expect(registry.language(forExtension: "go")?.languageID == "go")
        #expect(registry.language(forExtension: "lua")?.languageID == "lua")
    }

    // MARK: - Overlay semantics

    @Test func fixtureOverridesBundledEntryAndExtendsDefaults() {
        let result = loadFixture("override.toml")
        #expect(result.diagnostics.isEmpty)

        // Whole-entry replacement, not field-by-field merge.
        let python = result.registry.language(forLanguageID: "python")
        #expect(python?.grammar == "python")
        #expect(python?.binaryName == "pyright-langserver")
        #expect(python?.installCommand == "npm install -g pyright")
        // The leading-dot spelling normalizes; the bundled `pyw` is gone because
        // the entries replace each other whole.
        #expect(python?.extensions == ["py", "pyi"])
        #expect(result.registry.languages.filter { $0.languageID == "python" }.count == 1)

        // A new language is appended.
        #expect(result.registry.language(forExtension: "rs")?.languageID == "rust")

        // Unrelated bundled entries are untouched.
        #expect(result.registry.language(forExtension: "json")?.languageID == "json")
        #expect(result.registry.language(forExtension: "yml")?.languageID == "yaml")
    }

    @Test func duplicateExtensionLaterEntryWins() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["dup"]
            languageId = "first"
            grammar = "first-grammar"

            [[language]]
            extensions = ["dup"]
            languageId = "second"
            grammar = "second-grammar"
            """
        )

        #expect(result.diagnostics.isEmpty)
        #expect(result.registry.language(forExtension: "dup")?.languageID == "second")
    }

    @Test func userExtensionShadowsBundledExtension() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["md"]
            languageId = "custom-markdown"
            grammar = "markdown"
            """
        )

        #expect(result.registry.language(forExtension: "md")?.languageID == "custom-markdown")
        // The bundled entry is still present; only its extension claim is shadowed.
        #expect(result.registry.language(forLanguageID: "markdown") != nil)
    }

    @Test func duplicateLanguageIDLaterEntryWinsAndIsReported() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["aa"]
            languageId = "dup-id"
            grammar = "first-grammar"

            [[language]]
            extensions = ["bb"]
            languageId = "dup-id"
            grammar = "second-grammar"
            """
        )

        // Later entry wins, consistent with duplicate extensions.
        let language = result.registry.language(forLanguageID: "dup-id")
        #expect(language?.grammar == "second-grammar")
        #expect(language?.extensions == ["bb"])

        // ...and the collision is reported, pointing at the later entry.
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.entryIndex == 1)
        #expect(result.diagnostics.first?.languageID == "dup-id")
        #expect(result.diagnostics.first?.field == "languageId")
    }

    // MARK: - Validation / malformed input

    @Test func unknownFieldSkipsOnlyThatEntry() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["aa"]
            languageId = "good"
            grammar = "good-grammar"

            [[language]]
            extensions = ["bb"]
            languageId = "bad"
            grammar = "bad-grammar"
            bogus = true
            """
        )

        #expect(result.registry.language(forExtension: "aa")?.languageID == "good")
        #expect(result.registry.language(forLanguageID: "bad") == nil)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.field == "bogus")
        #expect(result.diagnostics.first?.languageID == "bad")
        #expect(result.diagnostics.first?.entryIndex == 1)
    }

    @Test func invalidFieldTypeSkipsOnlyThatEntry() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["cc"]
            languageId = "good"
            grammar = "good-grammar"

            [[language]]
            extensions = "not-an-array"
            languageId = "bad"
            grammar = "bad-grammar"
            """
        )

        #expect(result.registry.language(forExtension: "cc")?.languageID == "good")
        #expect(result.registry.language(forLanguageID: "bad") == nil)
        #expect(result.diagnostics.first?.field == "extensions")
        #expect(result.diagnostics.first?.languageID == "bad")
    }

    @Test func missingRequiredFieldIsReported() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["dd"]
            languageId = "no-grammar"
            """
        )

        #expect(result.registry.language(forLanguageID: "no-grammar") == nil)
        #expect(result.diagnostics.first?.field == "grammar")
    }

    @Test func missingLanguageIDIsReported() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["ee"]
            grammar = "g"
            """
        )

        #expect(result.diagnostics.first?.field == "languageId")
    }

    @Test func malformedTomlKeepsDefaultsAndSurfacesError() {
        let result = loadInline("[[language]\nextensions = [")

        #expect(!result.diagnostics.isEmpty)
        #expect(result.diagnostics.first?.entryIndex == nil)
        #expect(result.registry.languages == bundledResolved)
        #expect(result.registry.language(forExtension: "py")?.languageID == "python")
    }

    @Test func topLevelLanguageKeyMustBeArrayOfTables() {
        let result = loadInline("language = 3")

        #expect(!result.diagnostics.isEmpty)
        #expect(result.diagnostics.first?.field == "language")
        #expect(result.registry.languages == bundledResolved)
    }

    @Test func descriptionFormatsFileLevelFieldsWithoutPathDot() {
        let result = loadInline("language = 3")

        #expect(
            result.diagnostics.first?.description
                == "/tmp/languages.toml: field 'language': expected an array of tables (`[[language]]`)"
        )
    }

    @Test func unreadableConfigSurfacesDiagnosticWithoutCrashing() {
        // A directory exists at the path but cannot be read as a UTF-8 string.
        let result = LanguageConfigLoader.load(userConfigAt: fixturesDirectory)

        #expect(!result.diagnostics.isEmpty)
        #expect(result.registry.languages == bundledResolved)
    }

    // MARK: - Highlighting-only / lspPath

    @Test func highlightingOnlyEntryHasNoBinary() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["hl"]
            languageId = "hlonly"
            grammar = "hlonly"
            """
        )

        let language = result.registry.language(forLanguageID: "hlonly")
        #expect(language != nil)
        #expect(language?.binaryName == nil)
        #expect(language?.isHighlightingOnly == true)
    }

    @Test func literalLspPathIsPreserved() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["lua"]
            languageId = "lua"
            grammar = "lua"
            binaryName = "lua-language-server"
            installCommand = "brew install lua-language-server"
            lspPath = "/opt/homebrew/bin/lua-language-server"
            """
        )

        let language = result.registry.language(forLanguageID: "lua")
        #expect(language?.lspPath == "/opt/homebrew/bin/lua-language-server")
        #expect(language?.isHighlightingOnly == false)
    }

    @Test func lspOnlyFieldsWithoutBinaryNameAreRejected() {
        for lspOnlyField in ["installCommand", "lspPath"] {
            let result = loadInline(
                """
                [[language]]
                extensions = ["x"]
                languageId = "x"
                grammar = "x"
                \(lspOnlyField) = "value"
                """
            )

            #expect(result.registry.language(forLanguageID: "x") == nil, "\(lspOnlyField)")
            #expect(result.diagnostics.first?.field == lspOnlyField)
        }
    }

    // MARK: - Known-server catalog

    /// A user `[[knownServer]]` entry replaces the bundled catalog entry for the
    /// same `languageId` whole — adding, removing, and reordering candidates.
    @Test func knownServerOverrideReplacesCandidates() {
        let result = loadInline(
            """
            [[knownServer]]
            extensions = ["rs"]
            languageId = "rust"
            candidates = ["ra-custom"]
            installCommand = "custom install"
            """,
            bundledDefaults: [],
            bundledKnownServers: [BundledKnownServers.rust]
        )

        #expect(result.diagnostics.isEmpty)
        let rust = result.registry.language(forLanguageID: "rust")
        #expect(rust?.binaryAlternatives == ["ra-custom"])
        #expect(rust?.installCommand == "custom install")
        #expect(rust?.grammar == nil)
        #expect(rust?.isHighlightingOnly == false)
    }

    @Test func knownServerAddsNewReachableLanguage() {
        let result = loadInline(
            """
            [[knownServer]]
            extensions = ["rb"]
            languageId = "ruby"
            candidates = ["solargraph", "ruby-lsp"]
            """,
            bundledDefaults: [],
            bundledKnownServers: []
        )

        #expect(result.diagnostics.isEmpty)
        #expect(result.registry.language(forExtension: "rb")?.languageID == "ruby")
        let ruby = result.registry.language(forLanguageID: "ruby")
        #expect(ruby?.binaryAlternatives == ["solargraph", "ruby-lsp"])
        #expect(ruby?.grammar == nil)
    }

    /// A `[[language]]` entry claims its `languageId`, so the catalog entry is
    /// dropped: a server-less language entry is how a user disables autodetection.
    @Test func languageEntrySuppressesCatalogForSameID() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["rs"]
            languageId = "rust"
            grammar = "rust"
            """,
            bundledDefaults: [],
            bundledKnownServers: [BundledKnownServers.rust]
        )

        let rust = result.registry.language(forLanguageID: "rust")
        #expect(rust?.binaryName == nil)
        #expect(rust?.binaryAlternatives.isEmpty == true)
        #expect(rust?.isHighlightingOnly == true)
    }

    /// Explicit `binaryName` config wins; autodetection must not touch it.
    @Test func explicitBinaryNameWinsOverCatalog() {
        let result = loadInline(
            """
            [[language]]
            extensions = ["rs"]
            languageId = "rust"
            grammar = "rust"
            binaryName = "rust-analyzer-pinned"
            """,
            bundledDefaults: [],
            bundledKnownServers: [BundledKnownServers.rust]
        )

        let rust = result.registry.language(forLanguageID: "rust")
        #expect(rust?.binaryName == "rust-analyzer-pinned")
        #expect(rust?.binaryAlternatives.isEmpty == true)
    }

    @Test func knownServerRequiresExtensions() {
        let result = loadInline(
            """
            [[knownServer]]
            languageId = "ruby"
            candidates = ["solargraph"]
            """,
            bundledDefaults: [],
            bundledKnownServers: []
        )

        #expect(result.registry.language(forLanguageID: "ruby") == nil)
        #expect(result.diagnostics.first?.field == "extensions")
    }

    @Test func knownServerRequiresCandidates() {
        let result = loadInline(
            """
            [[knownServer]]
            extensions = ["rb"]
            languageId = "ruby"
            """,
            bundledDefaults: [],
            bundledKnownServers: []
        )

        #expect(result.registry.language(forLanguageID: "ruby") == nil)
        #expect(result.diagnostics.first?.field == "candidates")
    }

    @Test func knownServerUnknownFieldSkipsEntry() {
        let result = loadInline(
            """
            [[knownServer]]
            extensions = ["rb"]
            languageId = "ruby"
            candidates = ["solargraph"]
            bogus = true
            """,
            bundledDefaults: [],
            bundledKnownServers: []
        )

        #expect(result.registry.language(forLanguageID: "ruby") == nil)
        #expect(result.diagnostics.first?.field == "bogus")
    }

    @Test func duplicateKnownServerLanguageIDLaterWinsAndIsReported() {
        let result = loadInline(
            """
            [[knownServer]]
            extensions = ["rb"]
            languageId = "ruby"
            candidates = ["first"]

            [[knownServer]]
            extensions = ["rb"]
            languageId = "ruby"
            candidates = ["second"]
            """,
            bundledDefaults: [],
            bundledKnownServers: []
        )

        #expect(result.registry.language(forLanguageID: "ruby")?.binaryAlternatives == ["second"])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.field == "languageId")
        #expect(result.diagnostics.first?.languageID == "ruby")
        #expect(result.diagnostics.first?.entryIndex == 1)
    }
}
