import Testing
import OpenEditConfig
@testable import OpenEditLSP

@Suite struct LSPSettingsModelTests {
    private func makeModel(
        toml: String = "",
        availability: [String: LanguageServerAvailability] = [:]
    ) -> LSPSettingsModel {
        let loadResult = LanguageConfigLoader.load(
            userConfigContents: toml,
            configPath: "/tmp/languages.toml"
        )
        return LSPSettingsModel(
            loadResult: loadResult,
            availability: { language in
                availability[language.languageID]
                    ?? (language.isHighlightingOnly ? .highlightingOnly : .missing)
            }
        )
    }

    private func rowsByID(_ model: LSPSettingsModel) -> [String: LSPSettingsRow] {
        Dictionary(uniqueKeysWithValues: model.rows().map { ($0.languageID, $0) })
    }

    @Test func listsEveryRegistryLanguageOnceSortedByDisplayName() {
        let model = makeModel()

        #expect(
            model.rows().map(\.languageID)
                == ["go", "json", "lua", "markdown", "python", "rust", "toml", "yaml"]
        )
    }

    @Test func labelsBundledUserAndAutodetectedOrigins() {
        let model = makeModel(toml: """
        [[language]]
        extensions = ["py"]
        languageId = "python"
        grammar = "python"
        binaryName = "pylsp"
        """)

        let rows = rowsByID(model)
        #expect(rows["json"]?.origin == .bundled)
        #expect(rows["python"]?.origin == .userConfig)
        #expect(rows["rust"]?.origin == .autodetected)
    }

    @Test func mapsResolutionVerdictsToStatuses() {
        let model = makeModel(availability: [
            "python": .available(executablePath: "/opt/homebrew/bin/pylsp"),
            "rust": .missing,
            "json": .highlightingOnly
        ])

        let rows = rowsByID(model)
        #expect(rows["python"]?.status == .available(executablePath: "/opt/homebrew/bin/pylsp"))
        #expect(rows["rust"]?.status == .missing)
        #expect(rows["json"]?.status == .highlightingOnly)
    }

    @Test func availableRowCopiesItsResolvedPath() {
        let model = makeModel(availability: [
            "lua": .available(executablePath: "/opt/homebrew/bin/lua-language-server")
        ])

        let lua = rowsByID(model)["lua"]
        #expect(lua?.copyValue == "/opt/homebrew/bin/lua-language-server")
        #expect(lua?.needsOpenConfigAction == false)
    }

    @Test func missingCatalogRowOffersItsInstallCommandToCopy() {
        let python = rowsByID(makeModel())["python"]

        #expect(python?.status == .missing)
        #expect(python?.installCommand == "pip install python-lsp-server")
        #expect(python?.copyValue == "pip install python-lsp-server")
        #expect(python?.needsOpenConfigAction == false)
        #expect(python?.probedBinaries == ["pylsp", "pyright-langserver"])
    }

    @Test func missingRowWithoutACommandOffersOpenConfigInstead() {
        let model = makeModel(toml: """
        [[language]]
        extensions = ["rb"]
        languageId = "ruby"
        grammar = "ruby"
        binaryName = "ruby-lsp"
        """)

        let ruby = rowsByID(model)["ruby"]
        #expect(ruby?.status == .missing)
        #expect(ruby?.origin == .userConfig)
        #expect(ruby?.hasInstallCommand == false)
        #expect(ruby?.copyValue == nil)
        #expect(ruby?.needsOpenConfigAction == true)
    }

    @Test func highlightingOnlyRowHasNoCopyOrOpenConfigAction() {
        let json = rowsByID(makeModel())["json"]

        #expect(json?.status == .highlightingOnly)
        #expect(json?.copyValue == nil)
        #expect(json?.needsOpenConfigAction == false)
    }

    @Test func literalPathIsExposedAndTheCommandRemainsTheRemedy() {
        let model = makeModel(
            toml: """
            [[language]]
            extensions = ["py"]
            languageId = "python"
            grammar = "python"
            binaryName = "pylsp"
            lspPath = "/opt/venv/bin/pylsp"
            installCommand = "pip install python-lsp-server"
            """,
            availability: ["python": .missing]
        )
        let python = rowsByID(model)["python"]

        #expect(python?.lspPath == "/opt/venv/bin/pylsp")
        // A literal path is authoritative, so no PATH binaries were probed.
        #expect(python?.probedBinaries.isEmpty == true)
        #expect(python?.copyValue == "pip install python-lsp-server")
    }

    @Test func malformedConfigIsReportedAsUnattachedDiagnostic() {
        let model = makeModel(toml: "[[language]\n")

        #expect(model.allDiagnostics.count == 1)
        #expect(model.unattachedDiagnostics.count == 1)
        #expect(model.unattachedDiagnostics.first?.languageID == nil)
    }

    @Test func invalidEntryDiagnosticIsUnattachedWhenNoRowExists() {
        let model = makeModel(toml: """
        [[language]]
        extensions = []
        languageId = "ruby"
        grammar = "ruby"
        """)

        #expect(model.allDiagnostics.count == 1)
        #expect(model.unattachedDiagnostics.count == 1)
        #expect(model.unattachedDiagnostics.first?.languageID == "ruby")
    }

    @Test func entryDiagnosticIsAttachedToItsLanguageRow() {
        let model = makeModel(toml: """
        [[language]]
        extensions = ["py"]
        languageId = "python"
        grammar = "python"
        binaryName = "pylsp"

        [[language]]
        extensions = ["py"]
        languageId = "python"
        grammar = "python"
        binaryName = "pyright-langserver"
        """)

        let python = rowsByID(model)["python"]
        #expect(python?.origin == .userConfig)
        #expect(python?.diagnostics.count == 1)
        #expect(model.allDiagnostics.count == 1)
        #expect(model.unattachedDiagnostics.isEmpty)
    }
}