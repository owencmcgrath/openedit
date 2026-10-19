import Foundation
import TOMLKit

/// Reads `~/.config/openedit/languages.toml` and merges it over the bundled
/// defaults (ARCHITECTURE.md 5.2).
///
/// Loading the user file is optional: a missing file simply yields the bundled
/// defaults. A present file overrides and extends the defaults rather than
/// replacing them, and a single bad entry is skipped — with a diagnostic —
/// without disturbing the other mappings or the defaults.
///
/// Two arrays of tables are recognized: explicit `[[language]]` entries and the
/// autodetection catalog `[[knownServer]]` entries.
///
/// ```toml
/// [[language]]
/// extensions = ["py", "pyw"]        # required, non-empty
/// languageId = "python"             # required
/// grammar = "python"                # required for [[language]]
/// binaryName = "pylsp"              # optional; absent + no catalog means highlighting-only
/// installCommand = "pip install python-lsp-server"  # optional, LSP-only
/// lspPath = "/opt/venv/bin/pylsp"   # optional literal override, LSP-only
///
/// [[knownServer]]
/// extensions = ["rs"]               # required, non-empty: discovery is by extension
/// languageId = "rust"               # required
/// grammar = "rust"                  # optional; absent means LSP-only, plain text
/// candidates = ["rust-analyzer"]    # required, non-empty, ordered
/// installCommand = "rustup component add rust-analyzer"  # optional
/// ```
///
/// Decisions recorded for this task (also in ARCHITECTURE.md 5.2/5.6):
/// - No `binaryName` in a `[[language]]` entry means highlighting-only; a
///   language entry — even one with no server — claims its `languageId` and
///   suppresses autodetection for it. The catalog only fills gaps where no
///   `[[language]]` entry exists.
/// - Explicit `binaryName`/`lspPath` config always wins over a catalog candidate.
/// - `grammar` is optional on `[[knownServer]]`: a catalog-only language with no
///   bundled grammar is LSP-only and the text stays plain and editable.
/// - A user entry replaces the whole bundled entry with the same `languageId`
///   (in either array); a new `languageId` extends the list. Two user entries
///   with the same `languageId`: the later one wins and the collision is reported.
/// - Duplicate extensions: the later entry wins (user file is processed after
///   the bundled defaults), and there is no removal syntax in v1.
/// - An invalid entry is skipped and reported; its neighbors and the defaults
///   are untouched.
public enum LanguageConfigLoader {
    /// `~/.config/openedit/languages.toml`.
    public static var defaultUserConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("openedit", isDirectory: true)
            .appendingPathComponent("languages.toml", isDirectory: false)
    }

    /// Load the user config at `userConfigURL` (defaulting to the standard
    /// location) over `bundledDefaults`/`bundledKnownServers`.
    ///
    /// Never throws: unreadable files, malformed TOML, and invalid entries all
    /// come back as diagnostics with the defaults (or the surviving entries)
    /// intact.
    public static func load(
        userConfigAt userConfigURL: URL? = defaultUserConfigURL,
        bundledDefaults: [ResolvedLanguage] = BundledLanguages.all,
        bundledKnownServers: [KnownServer] = BundledKnownServers.all
    ) -> LanguageConfigLoadResult {
        guard let userConfigURL, FileManager.default.fileExists(atPath: userConfigURL.path) else {
            return bundledOnly(bundledDefaults, bundledKnownServers)
        }

        let configPath = userConfigURL.path
        let contents: String
        do {
            contents = try String(contentsOf: userConfigURL, encoding: .utf8)
        } catch {
            return result(
                languages: resolve(
                    bundledLanguages: bundledDefaults,
                    bundledKnownServers: bundledKnownServers,
                    userLanguages: [],
                    userKnownServers: []
                ),
                diagnostics: [
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        message: "Could not read config file: \(error.localizedDescription)"
                    )
                ]
            )
        }

        return load(
            userConfigContents: contents,
            configPath: configPath,
            bundledDefaults: bundledDefaults,
            bundledKnownServers: bundledKnownServers
        )
    }

    /// Parse already-read config text. Exposed separately from the file path so
    /// callers (and tests) can load config without touching the filesystem.
    public static func load(
        userConfigContents: String,
        configPath: String,
        bundledDefaults: [ResolvedLanguage] = BundledLanguages.all,
        bundledKnownServers: [KnownServer] = BundledKnownServers.all
    ) -> LanguageConfigLoadResult {
        let root: TOMLTable
        do {
            root = try TOMLTable(string: userConfigContents)
        } catch {
            return result(
                languages: resolve(
                    bundledLanguages: bundledDefaults,
                    bundledKnownServers: bundledKnownServers,
                    userLanguages: [],
                    userKnownServers: []
                ),
                diagnostics: [
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        message: "Invalid TOML: \(error)"
                    )
                ]
            )
        }

        var diagnostics: [LanguageConfigDiagnostic] = []

        let languageEntries = parseTableArray(root, key: "language", configPath: configPath)
        diagnostics.append(contentsOf: languageEntries.diagnostics)
        let userLanguages = parseLanguages(
            languageEntries.tables,
            configPath: configPath,
            diagnostics: &diagnostics
        )

        let knownServerEntries = parseTableArray(root, key: "knownServer", configPath: configPath)
        diagnostics.append(contentsOf: knownServerEntries.diagnostics)
        let userKnownServers = parseKnownServers(
            knownServerEntries.tables,
            configPath: configPath,
            diagnostics: &diagnostics
        )

        return result(
            languages: resolve(
                bundledLanguages: bundledDefaults,
                bundledKnownServers: bundledKnownServers,
                userLanguages: userLanguages,
                userKnownServers: userKnownServers
            ),
            diagnostics: diagnostics
        )
    }

    // MARK: - Top-level array parsing

    /// Reads an array-of-tables key (e.g. `[[language]]`). Absent means an empty
    /// list; a wrong type is a file-level diagnostic. Each element carries its
    /// original array index so entry diagnostics point at the right table.
    private static func parseTableArray(
        _ root: TOMLTable,
        key: String,
        configPath: String
    ) -> (tables: [(index: Int, table: TOMLTable)], diagnostics: [LanguageConfigDiagnostic]) {
        guard let value = root[key] else {
            // A file that only has comments (or no such key at all) is a valid,
            // empty overlay.
            return ([], [])
        }
        guard value.type == .array, let entries = value.array else {
            return ([], [
                LanguageConfigDiagnostic(
                    configPath: configPath,
                    field: key,
                    message: "expected an array of tables (`[[\(key)]]`)"
                )
            ])
        }

        var tables: [(index: Int, table: TOMLTable)] = []
        var diagnostics: [LanguageConfigDiagnostic] = []
        for (index, element) in entries.enumerated() {
            guard element.type == .table, let table = element.table else {
                diagnostics.append(
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        entryIndex: index,
                        message: "entry is not a table; expected `[[\(key)]]`"
                    )
                )
                continue
            }
            tables.append((index, table))
        }
        return (tables, diagnostics)
    }

    // MARK: - Language parsing

    private static func parseLanguages(
        _ tables: [(index: Int, table: TOMLTable)],
        configPath: String,
        diagnostics: inout [LanguageConfigDiagnostic]
    ) -> [ResolvedLanguage] {
        var userLanguages: [ResolvedLanguage] = []
        var seenUserIDs: [String: Int] = [:]

        for (index, table) in tables {
            let parsed = parseEntry(table, entryIndex: index, configPath: configPath)
            diagnostics.append(contentsOf: parsed.diagnostics)
            guard let language = parsed.language else { continue }
            if let previousIndex = seenUserIDs[language.languageID] {
                // Two user entries with the same `languageId` are almost
                // certainly a typo; the later one still wins (same rule as
                // duplicate extensions), but the collision is reported.
                diagnostics.append(
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        entryIndex: index,
                        languageID: language.languageID,
                        field: "languageId",
                        message: "duplicate `languageId`; this entry replaces the one at index \(previousIndex)"
                    )
                )
            }
            seenUserIDs[language.languageID] = index
            userLanguages.append(language)
        }
        return userLanguages
    }

    private static let knownFields: Set<String> = [
        "extensions", "languageId", "grammar", "binaryName", "installCommand", "lspPath"
    ]

    private static func parseEntry(
        _ table: TOMLTable,
        entryIndex: Int,
        configPath: String
    ) -> (language: ResolvedLanguage?, diagnostics: [LanguageConfigDiagnostic]) {
        var diagnostics: [LanguageConfigDiagnostic] = []

        // Read `languageId` first so later diagnostics can name the entry.
        var languageID: String?

        func report(field: String?, message: String) {
            diagnostics.append(
                LanguageConfigDiagnostic(
                    configPath: configPath,
                    entryIndex: entryIndex,
                    languageID: languageID,
                    field: field,
                    message: message
                )
            )
        }

        if let value = table["languageId"] {
            if value.type == .string, let identifier = value.string, !identifier.isEmpty {
                languageID = identifier
            } else {
                report(field: "languageId", message: "expected a non-empty string")
            }
        } else {
            report(field: "languageId", message: "missing required field")
        }

        for key in table.keys where !knownFields.contains(key) {
            report(field: key, message: "unknown field")
        }

        let extensions = requiredExtensions(table, report: report)
        let grammar = requiredString(table, field: "grammar", report: report)

        let binaryName = optionalString(table, field: "binaryName", report: report)
        let installCommand = optionalString(table, field: "installCommand", report: report)
        let lspPath = optionalString(table, field: "lspPath", report: report)

        if binaryName == nil {
            if installCommand != nil {
                report(field: "installCommand", message: "requires `binaryName` (no LSP without it)")
            }
            if lspPath != nil {
                report(field: "lspPath", message: "requires `binaryName` (no LSP without it)")
            }
        }

        // Any diagnostic means the whole entry is skipped, so one bad entry can
        // never partially redefine a mapping.
        guard diagnostics.isEmpty,
              let languageID,
              let extensions,
              let grammar
        else {
            return (nil, diagnostics)
        }

        return (
            ResolvedLanguage(
                languageID: languageID,
                extensions: extensions,
                grammar: grammar,
                binaryName: binaryName,
                installCommand: installCommand,
                lspPath: lspPath
            ),
            diagnostics
        )
    }

    // MARK: - Known-server parsing

    private static func parseKnownServers(
        _ tables: [(index: Int, table: TOMLTable)],
        configPath: String,
        diagnostics: inout [LanguageConfigDiagnostic]
    ) -> [KnownServer] {
        var userServers: [KnownServer] = []
        var seenUserIDs: [String: Int] = [:]

        for (index, table) in tables {
            let parsed = parseKnownServer(table, entryIndex: index, configPath: configPath)
            diagnostics.append(contentsOf: parsed.diagnostics)
            guard let server = parsed.server else { continue }
            if let previousIndex = seenUserIDs[server.languageID] {
                diagnostics.append(
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        entryIndex: index,
                        languageID: server.languageID,
                        field: "languageId",
                        message: "duplicate `languageId`; this entry replaces the one at index \(previousIndex)"
                    )
                )
            }
            seenUserIDs[server.languageID] = index
            userServers.append(server)
        }
        return userServers
    }

    private static let knownServerFields: Set<String> = [
        "languageId", "extensions", "grammar", "candidates", "installCommand"
    ]

    private static func parseKnownServer(
        _ table: TOMLTable,
        entryIndex: Int,
        configPath: String
    ) -> (server: KnownServer?, diagnostics: [LanguageConfigDiagnostic]) {
        var diagnostics: [LanguageConfigDiagnostic] = []
        var languageID: String?

        func report(field: String?, message: String) {
            diagnostics.append(
                LanguageConfigDiagnostic(
                    configPath: configPath,
                    entryIndex: entryIndex,
                    languageID: languageID,
                    field: field,
                    message: message
                )
            )
        }

        if let value = table["languageId"] {
            if value.type == .string, let identifier = value.string, !identifier.isEmpty {
                languageID = identifier
            } else {
                report(field: "languageId", message: "expected a non-empty string")
            }
        } else {
            report(field: "languageId", message: "missing required field")
        }

        for key in table.keys where !knownServerFields.contains(key) {
            report(field: key, message: "unknown field")
        }

        // Extensions are required: discovery is keyed by real file extensions, so
        // a catalog entry without any could never be reached (5.2).
        let extensions = requiredExtensions(table, report: report)
        let candidates = requiredStringArray(table, field: "candidates", report: report)
        let grammar = optionalString(table, field: "grammar", report: report)
        let installCommand = optionalString(table, field: "installCommand", report: report)

        guard diagnostics.isEmpty,
              let languageID,
              let extensions,
              let candidates
        else {
            return (nil, diagnostics)
        }

        return (
            KnownServer(
                languageID: languageID,
                extensions: extensions,
                grammar: grammar,
                candidates: candidates,
                installCommand: installCommand
            ),
            diagnostics
        )
    }

    // MARK: - Field helpers

    private static func requiredExtensions(
        _ table: TOMLTable,
        report: (String?, String) -> Void
    ) -> [String]? {
        guard let value = table["extensions"] else {
            report("extensions", "missing required field")
            return nil
        }
        guard value.type == .array, let array = value.array else {
            report("extensions", "expected an array of strings")
            return nil
        }
        guard !array.isEmpty else {
            report("extensions", "expected at least one extension")
            return nil
        }

        var extensions: [String] = []
        for element in array {
            guard element.type == .string, let rawExtension = element.string else {
                report("extensions", "expected an array of strings")
                return nil
            }
            let normalized = ResolvedLanguage.normalizedExtension(rawExtension)
            guard !normalized.isEmpty else {
                report("extensions", "extension must not be empty")
                return nil
            }
            extensions.append(normalized)
        }
        return extensions
    }

    private static func requiredStringArray(
        _ table: TOMLTable,
        field: String,
        report: (String?, String) -> Void
    ) -> [String]? {
        guard let value = table[field] else {
            report(field, "missing required field")
            return nil
        }
        guard value.type == .array, let array = value.array else {
            report(field, "expected an array of strings")
            return nil
        }
        guard !array.isEmpty else {
            report(field, "expected at least one entry")
            return nil
        }
        var strings: [String] = []
        for element in array {
            guard element.type == .string, let string = element.string, !string.isEmpty else {
                report(field, "expected an array of non-empty strings")
                return nil
            }
            strings.append(string)
        }
        return strings
    }

    private static func requiredString(
        _ table: TOMLTable,
        field: String,
        report: (String?, String) -> Void
    ) -> String? {
        guard let value = table[field] else {
            report(field, "missing required field")
            return nil
        }
        guard value.type == .string, let string = value.string, !string.isEmpty else {
            report(field, "expected a non-empty string")
            return nil
        }
        return string
    }

    private static func optionalString(
        _ table: TOMLTable,
        field: String,
        report: (String?, String) -> Void
    ) -> String? {
        guard let value = table[field] else { return nil }
        guard value.type == .string, let string = value.string, !string.isEmpty else {
            report(field, "expected a non-empty string")
            return nil
        }
        return string
    }

    // MARK: - Merging

    /// Bundled defaults first, then user entries: a same-`languageId` user entry
    /// replaces the bundled one in place, a new one is appended. Because user
    /// entries come later in the array, they also win the duplicate-extension
    /// race when the registry builds its extension index.
    private static func merge(
        _ bundledDefaults: [ResolvedLanguage],
        with userLanguages: [ResolvedLanguage]
    ) -> [ResolvedLanguage] {
        var merged = bundledDefaults
        var indexByLanguageID: [String: Int] = [:]
        for (index, language) in merged.enumerated() {
            indexByLanguageID[language.languageID] = index
        }

        for language in userLanguages {
            if let existingIndex = indexByLanguageID[language.languageID] {
                merged[existingIndex] = language
            } else {
                indexByLanguageID[language.languageID] = merged.count
                merged.append(language)
            }
        }
        return merged
    }

    /// Same whole-entry replacement rule as `merge`, for the catalog.
    private static func mergeKnownServers(
        _ bundledServers: [KnownServer],
        with userServers: [KnownServer]
    ) -> [KnownServer] {
        var merged = bundledServers
        var indexByLanguageID: [String: Int] = [:]
        for (index, server) in merged.enumerated() {
            indexByLanguageID[server.languageID] = index
        }

        for server in userServers {
            if let existingIndex = indexByLanguageID[server.languageID] {
                merged[existingIndex] = server
            } else {
                indexByLanguageID[server.languageID] = merged.count
                merged.append(server)
            }
        }
        return merged
    }

    /// Combine explicit language entries and the autodetection catalog into the
    /// registry list. A `[[language]]` entry claims its `languageId`: the catalog
    /// entry for that ID is dropped (explicit config wins, and a server-less
    /// language entry is how a user says "do not autodetect here"). Catalog-only
    /// languages are prepended so explicit language entries win any
    /// duplicate-extension race (the registry's later-wins rule).
    private static func resolve(
        bundledLanguages: [ResolvedLanguage],
        bundledKnownServers: [KnownServer],
        userLanguages: [ResolvedLanguage],
        userKnownServers: [KnownServer]
    ) -> [ResolvedLanguage] {
        let languages = merge(bundledLanguages, with: userLanguages)
        let servers = mergeKnownServers(bundledKnownServers, with: userKnownServers)
        let claimedIDs = Set(languages.map(\.languageID))
        let catalogLanguages = servers
            .filter { !claimedIDs.contains($0.languageID) }
            .map(\.asResolvedLanguage)
        return catalogLanguages + languages
    }

    private static func bundledOnly(
        _ bundledDefaults: [ResolvedLanguage],
        _ bundledKnownServers: [KnownServer]
    ) -> LanguageConfigLoadResult {
        result(
            languages: resolve(
                bundledLanguages: bundledDefaults,
                bundledKnownServers: bundledKnownServers,
                userLanguages: [],
                userKnownServers: []
            ),
            diagnostics: []
        )
    }

    private static func result(
        languages: [ResolvedLanguage],
        diagnostics: [LanguageConfigDiagnostic]
    ) -> LanguageConfigLoadResult {
        LanguageConfigLoadResult(registry: LanguageRegistry(languages: languages), diagnostics: diagnostics)
    }
}
