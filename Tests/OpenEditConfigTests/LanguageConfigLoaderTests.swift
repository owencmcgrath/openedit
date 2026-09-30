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

    private func loadInline(_ toml: String) -> LanguageConfigLoadResult {
        LanguageConfigLoader.load(userConfigContents: toml, configPath: "/tmp/languages.toml")
    }

    // MARK: - Missing file / bundled defaults

    @Test func missingFileUsesBundledDefaultsWithoutDiagnostics() {
        let result = LanguageConfigLoader.load(
            userConfigAt: fixturesDirectory.appendingPathComponent("does-not-exist.toml")
        )

        #expect(result.diagnostics.isEmpty)
        #expect(result.registry.languages == BundledLanguages.all)
        #expect(result.registry.language(forExtension: "py")?.languageID == "python")
    }

    @Test func emptyOverlayKeepsBundledDefaults() {
        let result = loadInline("# nothing but comments\n")

        #expect(result.diagnostics.isEmpty)
        #expect(result.registry.languages == BundledLanguages.all)
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
        let byID = Dictionary(uniqueKeysWithValues: BundledLanguages.all.map { ($0.languageID, $0) })

        #expect(Set(byID.keys) == ["python", "json", "markdown", "toml", "yaml"])
        #expect(byID["python"]?.extensions == ["py", "pyw"])
        #expect(byID["python"]?.binaryName == "pylsp")
        #expect(byID["markdown"]?.extensions == ["md", "markdown"])
        #expect(byID["yaml"]?.extensions == ["yaml", "yml"])

        for highlightingOnlyID in ["json", "markdown", "toml", "yaml"] {
            #expect(byID[highlightingOnlyID]?.isHighlightingOnly == true, "\(highlightingOnlyID)")
        }
        #expect(byID["python"]?.isHighlightingOnly == false)
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
        #expect(result.registry.languages == BundledLanguages.all)
        #expect(result.registry.language(forExtension: "py")?.languageID == "python")
    }

    @Test func topLevelLanguageKeyMustBeArrayOfTables() {
        let result = loadInline("language = 3")

        #expect(!result.diagnostics.isEmpty)
        #expect(result.diagnostics.first?.field == "language")
        #expect(result.registry.languages == BundledLanguages.all)
    }

    @Test func unreadableConfigSurfacesDiagnosticWithoutCrashing() {
        // A directory exists at the path but cannot be read as a UTF-8 string.
        let result = LanguageConfigLoader.load(userConfigAt: fixturesDirectory)

        #expect(!result.diagnostics.isEmpty)
        #expect(result.registry.languages == BundledLanguages.all)
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
}
