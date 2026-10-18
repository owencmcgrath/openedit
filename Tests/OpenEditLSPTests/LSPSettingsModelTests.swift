import Foundation
import Testing
import OpenEditConfig
@testable import OpenEditLSP

@Suite struct LSPSettingsModelTests {
    private func makeStore() -> MissingLSPSuppressionStore {
        let suiteName = "LSPSettingsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MissingLSPSuppressionStore(defaults: defaults)
    }

    private func makeModel(
        toml: String = "",
        store: MissingLSPSuppressionStore? = nil,
        availability: [String: LanguageServerAvailability] = [:]
    ) -> LSPSettingsModel {
        let loadResult = LanguageConfigLoader.load(
            userConfigContents: toml,
            configPath: "/tmp/languages.toml"
        )
        return LSPSettingsModel(
            loadResult: loadResult,
            store: store ?? makeStore(),
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
        #expect(rows["json"]?.canToggleNotifications == false)
        #expect(rows["rust"]?.canToggleNotifications == true)
    }

    @Test func missingCatalogRowKeepsInstallCommandAndProbedBinaries() {
        let python = rowsByID(makeModel())["python"]

        #expect(python?.status == .missing)
        #expect(python?.installCommand == "pip install python-lsp-server")
        #expect(python?.probedBinaries == ["pylsp", "pyright-langserver"])
    }

    @Test func literalPathIsExposedAndSearchable() {
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
        #expect(model.rows(matching: "venv").map(\.languageID) == ["python"])
        #expect(model.rows(matching: "pip install").map(\.languageID) == ["python"])
    }

    @Test func staleDismissalStaysListedUntilReset() {
        let store = makeStore()
        store.suppress(languageID: "ruby")
        var model = makeModel(store: store)

        let stale = rowsByID(model)["ruby"]
        #expect(stale?.status == .noLongerConfigured)
        #expect(stale?.origin == nil)
        #expect(stale?.displayName == "Ruby")
        #expect(stale?.isNotificationSuppressed == true)
        #expect(stale?.canToggleNotifications == true)

        model.setNotificationsEnabled(true, for: "ruby")

        #expect(!store.isSuppressed(languageID: "ruby"))
        #expect(rowsByID(model)["ruby"] == nil)
    }

    @Test func notificationToggleWritesTheSamePerLanguageKey() {
        let store = makeStore()
        store.suppress(languageID: "python")
        var model = makeModel(store: store)

        #expect(rowsByID(model)["python"]?.isNotificationSuppressed == true)

        model.setNotificationsEnabled(true, for: "python")
        #expect(!store.isSuppressed(languageID: "python"))
        #expect(rowsByID(model)["python"]?.isNotificationSuppressed == false)

        model.setNotificationsEnabled(false, for: "rust")
        #expect(store.isSuppressed(languageID: "rust"))
        #expect(!store.isSuppressed(languageID: "python"))
        #expect(rowsByID(model)["rust"]?.isNotificationSuppressed == true)
    }

    @Test func highlightingOnlyCannotBeSuppressedFromSettings() {
        let store = makeStore()
        var model = makeModel(store: store)

        model.setNotificationsEnabled(false, for: "json")

        #expect(!store.isSuppressed(languageID: "json"))
        #expect(rowsByID(model)["json"]?.isNotificationSuppressed == false)
    }

    @Test func searchMatchesNameExtensionStatusAndOrigin() {
        let model = makeModel(availability: ["python": .missing])

        #expect(model.rows(matching: "python").map(\.languageID) == ["python"])
        #expect(model.rows(matching: "python missing").map(\.languageID) == ["python"])
        #expect(model.rows(matching: "py").map(\.languageID) == ["python"])
        #expect(model.rows(matching: "pylsp").map(\.languageID) == ["python"])
        #expect(
            model.rows(matching: "autodetected").map(\.languageID)
                == ["go", "lua", "python", "rust"]
        )
        #expect(
            model.rows(matching: "bundled").map(\.languageID)
                == ["json", "markdown", "toml", "yaml"]
        )
        #expect(model.rows(matching: "no such language").isEmpty)
    }

    @Test func userConfigSearchFindsOverriddenLanguage() {
        let model = makeModel(toml: """
        [[language]]
        extensions = ["py"]
        languageId = "python"
        grammar = "python"
        binaryName = "pylsp"
        """)

        #expect(model.rows(matching: "your config").map(\.languageID) == ["python"])
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
