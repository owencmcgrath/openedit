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
/// Schema (conceptually a list of entries):
///
/// ```toml
/// [[language]]
/// extensions = ["py", "pyw"]        # required, non-empty
/// languageId = "python"             # required
/// grammar = "python"                # required
/// binaryName = "pylsp"              # optional; absent means highlighting-only
/// installCommand = "pip install python-lsp-server"  # optional, LSP-only
/// lspPath = "/opt/venv/bin/pylsp"   # optional literal override, LSP-only
/// ```
///
/// Decisions recorded for this task (also in ARCHITECTURE.md 5.2):
/// - No `binaryName` means highlighting-only; `installCommand` is optional even
///   when `binaryName` is present.
/// - A user entry replaces the whole bundled entry with the same `languageId`;
///   a new `languageId` extends the list. Two user entries with the same
///   `languageId`: the later one wins and the collision is reported.
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
    /// location) over `bundledDefaults`.
    ///
    /// Never throws: unreadable files, malformed TOML, and invalid entries all
    /// come back as diagnostics with the defaults (or the surviving entries)
    /// intact.
    public static func load(
        userConfigAt userConfigURL: URL? = defaultUserConfigURL,
        bundledDefaults: [ResolvedLanguage] = BundledLanguages.all
    ) -> LanguageConfigLoadResult {
        guard let userConfigURL, FileManager.default.fileExists(atPath: userConfigURL.path) else {
            return bundledOnly(bundledDefaults)
        }

        let configPath = userConfigURL.path
        let contents: String
        do {
            contents = try String(contentsOf: userConfigURL, encoding: .utf8)
        } catch {
            return result(
                languages: bundledDefaults,
                diagnostics: [
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        message: "Could not read config file: \(error.localizedDescription)"
                    )
                ]
            )
        }

        return load(userConfigContents: contents, configPath: configPath, bundledDefaults: bundledDefaults)
    }

    /// Parse already-read config text. Exposed separately from the file path so
    /// callers (and tests) can load config without touching the filesystem.
    public static func load(
        userConfigContents: String,
        configPath: String,
        bundledDefaults: [ResolvedLanguage] = BundledLanguages.all
    ) -> LanguageConfigLoadResult {
        let root: TOMLTable
        do {
            root = try TOMLTable(string: userConfigContents)
        } catch {
            return result(
                languages: bundledDefaults,
                diagnostics: [
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        message: "Invalid TOML: \(error)"
                    )
                ]
            )
        }

        guard let languageValue = root["language"] else {
            // A file that only has comments (or no `[[language]]` at all) is a
            // valid, empty overlay.
            return bundledOnly(bundledDefaults)
        }
        guard languageValue.type == .array, let entries = languageValue.array else {
            return result(
                languages: bundledDefaults,
                diagnostics: [
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        field: "language",
                        message: "expected an array of tables (`[[language]]`)"
                    )
                ]
            )
        }

        var diagnostics: [LanguageConfigDiagnostic] = []
        var userLanguages: [ResolvedLanguage] = []
        var seenUserIDs: [String: Int] = [:]

        for (index, element) in entries.enumerated() {
            guard element.type == .table, let table = element.table else {
                diagnostics.append(
                    LanguageConfigDiagnostic(
                        configPath: configPath,
                        entryIndex: index,
                        message: "entry is not a table; expected `[[language]]`"
                    )
                )
                continue
            }

            let parsed = parseEntry(table, entryIndex: index, configPath: configPath)
            diagnostics.append(contentsOf: parsed.diagnostics)
            if let language = parsed.language {
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
        }

        return result(
            languages: merge(bundledDefaults, with: userLanguages),
            diagnostics: diagnostics
        )
    }

    // MARK: - Entry parsing

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

    private static func bundledOnly(_ bundledDefaults: [ResolvedLanguage]) -> LanguageConfigLoadResult {
        result(languages: bundledDefaults, diagnostics: [])
    }

    private static func result(
        languages: [ResolvedLanguage],
        diagnostics: [LanguageConfigDiagnostic]
    ) -> LanguageConfigLoadResult {
        LanguageConfigLoadResult(registry: LanguageRegistry(languages: languages), diagnostics: diagnostics)
    }
}
