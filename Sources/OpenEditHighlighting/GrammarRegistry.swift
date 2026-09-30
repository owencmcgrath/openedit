import Foundation
import SwiftTreeSitter

import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterTOML
import TreeSitterYAML

/// Why a document is not highlighted. Surfaced so an unmapped extension or a
/// missing grammar is diagnosable rather than silently plain text
/// (ARCHITECTURE.md 5.4). Highlighting failure is never fatal: the text stays
/// plain and fully editable.
public enum HighlightingDiagnostic: Error, Equatable, Sendable {
    /// The config registry has no entry claiming the file's extension.
    case noLanguageMapping(fileExtension: String?)

    /// The registry maps the file to a grammar this build does not bundle.
    case grammarNotBundled(grammarName: String)

    /// The grammar ships in this build but its highlight query could not be
    /// loaded (missing resource bundle, unreadable query, query compile error).
    case queryLoadFailed(grammarName: String, message: String)

    public var description: String {
        switch self {
        case let .noLanguageMapping(fileExtension):
            let suffix = fileExtension.map { ".\($0)" } ?? "(no extension)"
            return "no language mapping for \(suffix); showing plain text"
        case let .grammarNotBundled(grammarName):
            return "grammar '\(grammarName)' is not bundled with this build; showing plain text"
        case let .queryLoadFailed(grammarName, message):
            return "could not load highlight queries for grammar '\(grammarName)': \(message)"
        }
    }
}

/// Maps a config grammar name (ARCHITECTURE.md 5.2's `grammar` field) to a
/// ready-to-use `LanguageConfiguration` — the tree-sitter parser plus its
/// bundled `highlights.scm`. One configuration per bundled grammar, resolved
/// once and shared.
public struct GrammarRegistry: Sendable {
    /// The grammars compiled into this build, keyed by the names the bundled
    /// config uses. Kept separate from the config registry so this module has no
    /// dependency on `OpenEditConfig` (see the component map).
    public static let bundledGrammarNames: Set<String> = [
        "python", "json", "markdown", "toml", "yaml"
    ]

    private let configurations: [String: Result<LanguageConfiguration, HighlightingDiagnostic>]

    public init() {
        self.init(queriesDirectoryProvider: { GrammarRegistry.defaultQueriesDirectory(forBundleName: $0) })
    }

    /// Test seam: let a caller point at an explicit queries directory instead of
    /// the SPM resource-bundle layout. The provider returns the directory that
    /// holds `highlights.scm` for a given bundle name, or `nil` if not found.
    public init(queriesDirectoryProvider: @Sendable (String) -> URL?) {
        var configurations: [String: Result<LanguageConfiguration, HighlightingDiagnostic>] = [:]
        for grammar in Self.bundledGrammars {
            configurations[grammar.name] = Self.makeConfiguration(
                grammar,
                queriesDirectoryProvider: queriesDirectoryProvider
            )
        }
        self.configurations = configurations
    }

    /// Resolve the grammar named by the config. Returns a diagnostic instead of
    /// a configuration when the grammar is not bundled or its queries failed to
    /// load.
    public func configuration(forGrammar grammarName: String) -> Result<LanguageConfiguration, HighlightingDiagnostic> {
        configurations[grammarName] ?? .failure(.grammarNotBundled(grammarName: grammarName))
    }

    // MARK: - Bundled grammar table

    private struct BundledGrammar {
        let name: String
        let language: Language
        let bundleName: String
    }

    private static let bundledGrammars: [BundledGrammar] = [
        BundledGrammar(
            name: "python",
            language: Language(language: tree_sitter_python()),
            bundleName: "TreeSitterPython_TreeSitterPython"
        ),
        BundledGrammar(
            name: "json",
            language: Language(language: tree_sitter_json()),
            bundleName: "TreeSitterJSON_TreeSitterJSON"
        ),
        BundledGrammar(
            name: "markdown",
            language: Language(language: tree_sitter_markdown()),
            bundleName: "TreeSitterMarkdown_TreeSitterMarkdown"
        ),
        BundledGrammar(
            name: "toml",
            language: Language(language: tree_sitter_toml()),
            bundleName: "TreeSitterTOML_TreeSitterTOML"
        ),
        BundledGrammar(
            name: "yaml",
            language: Language(language: tree_sitter_yaml()),
            bundleName: "TreeSitterYAML_TreeSitterYAML"
        )
    ]

    private static func makeConfiguration(
        _ grammar: BundledGrammar,
        queriesDirectoryProvider: (String) -> URL?
    ) -> Result<LanguageConfiguration, HighlightingDiagnostic> {
        guard let queriesDirectory = queriesDirectoryProvider(grammar.bundleName) else {
            return .failure(
                .queryLoadFailed(
                    grammarName: grammar.name,
                    message: "resource bundle \(grammar.bundleName).bundle not found"
                )
            )
        }

        do {
            return .success(
                try LanguageConfiguration(grammar.language, name: grammar.name, queriesURL: queriesDirectory)
            )
        } catch {
            return .failure(.queryLoadFailed(grammarName: grammar.name, message: String(describing: error)))
        }
    }

    // MARK: - SPM resource bundle lookup

    /// SwiftPM builds one `.bundle` per grammar target and leaves it next to the
    /// executable (`swift run` / `swift test`) or, once `Scripts/build-app.sh`
    /// has run, in `OpenEdit.app/Contents/Resources`. Search every container the
    /// three launch paths use so the same code works everywhere.
    static func defaultQueriesDirectory(forBundleName bundleName: String) -> URL? {
        // Seeds that differ per launch path: a bundled app (Contents/Resources),
        // `swift run` (next to the executable), and `swift test` (next to the
        // `.xctest`, which may be several levels above Bundle.main). Walk each
        // seed's ancestors so all three are covered without hard-coding depth.
        var seeds: [URL] = [Bundle.main.bundleURL]
        if let resourceURL = Bundle.main.resourceURL {
            seeds.append(resourceURL)
        }
        // `Bundle(for:)` finds the bundle that actually loaded this module: the
        // app (Contents/Resources lives under it) or the test `.xctest` next to
        // the grammar bundles. `Bundle.main` is useless under `swift test`,
        // where the process is a generic xctest helper.
        seeds.append(Bundle(for: BundleToken.self).bundleURL)
        seeds.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        if let testBundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            seeds.append(testBundle.bundleURL.deletingLastPathComponent())
        }

        for seed in seeds {
            var container: URL? = seed
            for _ in 0..<6 {
                guard let candidate = container else { break }
                let queries = candidate
                    .appendingPathComponent("\(bundleName).bundle", isDirectory: true)
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("queries", isDirectory: true)
                if FileManager.default.fileExists(atPath: queries.path) {
                    return queries
                }
                container = candidate.deletingLastPathComponent()
            }
        }
        return nil
    }
}

/// Anchor for `Bundle(for:)` so the module can locate the bundle that loaded it.
private final class BundleToken {}
