import Foundation
import Testing
import OpenEditConfig
@testable import OpenEditLSP

@Suite struct LanguageServerLocatorTests {
    private func language(
        binaryName: String? = "pylsp",
        lspPath: String? = nil
    ) -> ResolvedLanguage {
        ResolvedLanguage(
            languageID: "python",
            extensions: ["py"],
            grammar: "python",
            binaryName: binaryName,
            installCommand: "pip install python-lsp-server",
            lspPath: lspPath
        )
    }

    @Test func findsExecutableOnControlledPath() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: "/usr/bin:/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pylsp" }
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/pylsp"))
    }

    @Test func earlierPathEntryWins() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: "/first:/second",
            isExecutableFile: { $0 == "/first/pylsp" || $0 == "/second/pylsp" }
        )

        #expect(availability == .available(executablePath: "/first/pylsp"))
    }

    @Test func missingBinaryIsReported() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { _ in false }
        )

        #expect(availability == .missing)
    }

    @Test func literalPathIsUsedWhenExecutable() {
        let availability = LanguageServerLocator.resolve(
            language: language(lspPath: "/opt/venv/bin/pylsp"),
            pathEnvironment: "/usr/bin",
            isExecutableFile: { $0 == "/opt/venv/bin/pylsp" }
        )

        #expect(availability == .available(executablePath: "/opt/venv/bin/pylsp"))
    }

    /// A configured literal path is authoritative: an invalid one is a miss
    /// even if a same-named binary exists on PATH.
    @Test func invalidLiteralPathDoesNotFallBackToPath() {
        let availability = LanguageServerLocator.resolve(
            language: language(lspPath: "/missing/pylsp"),
            pathEnvironment: "/usr/bin",
            isExecutableFile: { $0 == "/usr/bin/pylsp" }
        )

        #expect(availability == .missing)
    }

    @Test func highlightingOnlyNeverResolves() {
        let availability = LanguageServerLocator.resolve(
            language: language(binaryName: nil),
            pathEnvironment: "/usr/bin",
            isExecutableFile: { _ in true }
        )

        #expect(availability == .highlightingOnly)
    }

    // MARK: - Catalog autodetection

    private func catalogLanguage(candidates: [String]) -> ResolvedLanguage {
        ResolvedLanguage(
            languageID: "python",
            extensions: ["py"],
            grammar: "python",
            installCommand: "pip install python-lsp-server",
            binaryAlternatives: candidates
        )
    }

    @Test func catalogCandidateProbedInOrderFirstHitWins() {
        let availability = LanguageServerLocator.resolve(
            language: catalogLanguage(candidates: ["pylsp", "pyright-langserver"]),
            pathEnvironment: "/usr/bin:/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pyright-langserver" }
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/pyright-langserver"))
    }

    @Test func catalogLaterCandidateWinsWhenEarlierMissing() {
        let availability = LanguageServerLocator.resolve(
            language: catalogLanguage(candidates: ["pylsp", "pyright-langserver"]),
            pathEnvironment: "/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pyright-langserver" }
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/pyright-langserver"))
    }

    /// All candidates missing is a `.missing` verdict (so #7 posts the catalog's
    /// install command), not `.highlightingOnly`.
    @Test func catalogAllMissingIsMissing() {
        let availability = LanguageServerLocator.resolve(
            language: catalogLanguage(candidates: ["pylsp", "pyright-langserver"]),
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { _ in false }
        )

        #expect(availability == .missing)
    }

    /// Explicit `binaryName` config wins: an available catalog alternative must
    /// not rescue a missing explicit binary.
    @Test func explicitBinaryNameWinsOverCatalogCandidates() {
        let explicit = ResolvedLanguage(
            languageID: "python",
            extensions: ["py"],
            grammar: "python",
            binaryName: "pylsp",
            binaryAlternatives: ["pyright-langserver"]
        )
        let availability = LanguageServerLocator.resolve(
            language: explicit,
            pathEnvironment: "/opt/homebrew/bin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/pyright-langserver" }
        )

        #expect(availability == .missing)
    }

    /// A catalog language with no grammar (LSP-only) still resolves a server;
    /// grammar absence must not force highlighting-only.
    @Test func catalogLanguageWithoutGrammarStillResolves() {
        let rust = ResolvedLanguage(
            languageID: "rust",
            extensions: ["rs"],
            grammar: nil,
            binaryAlternatives: ["rust-analyzer"]
        )
        let availability = LanguageServerLocator.resolve(
            language: rust,
            pathEnvironment: "/usr/local/bin",
            isExecutableFile: { $0 == "/usr/local/bin/rust-analyzer" }
        )

        #expect(availability == .available(executablePath: "/usr/local/bin/rust-analyzer"))
        #expect(rust.isHighlightingOnly == false)
    }

    /// No `PATH` in the environment must still check the documented fallback
    /// locations, not silently fail.
    @Test func absentPathVariableUsesFallback() {
        let availability = LanguageServerLocator.resolve(
            language: language(),
            pathEnvironment: nil,
            isExecutableFile: { $0 == "/usr/local/bin/pylsp" }
        )

        #expect(availability == .available(executablePath: "/usr/local/bin/pylsp"))
    }
}

@Suite struct WellKnownInstallDirectoryTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    private func language(binaryName: String? = nil, candidates: [String] = []) -> ResolvedLanguage {
        ResolvedLanguage(
            languageID: "go",
            extensions: ["go"],
            grammar: nil,
            binaryName: binaryName,
            binaryAlternatives: candidates
        )
    }

    /// A GUI launch has no `/opt/homebrew/bin` on `PATH`; the well-known list
    /// must still find an Apple Silicon Homebrew install.
    @Test func homebrewAppleSiliconDirectoryProbedWhenPathPresent() {
        let availability = LanguageServerLocator.resolve(
            language: language(binaryName: "gopls"),
            pathEnvironment: "/usr/bin:/bin:/usr/sbin:/sbin",
            isExecutableFile: { $0 == "/opt/homebrew/bin/gopls" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/opt/homebrew/bin/gopls"))
    }

    /// `~` entries expand against the home directory: rustup's `~/.cargo/bin`
    /// and `go install`'s `~/go/bin`.
    @Test func homeRelativeWellKnownDirectoriesAreExpanded() {
        let rust = ResolvedLanguage(
            languageID: "rust",
            extensions: ["rs"],
            grammar: nil,
            binaryAlternatives: ["rust-analyzer"]
        )
        let availability = LanguageServerLocator.resolve(
            language: rust,
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { $0 == "/Users/test/.cargo/bin/rust-analyzer" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/Users/test/.cargo/bin/rust-analyzer"))
    }

    @Test func goBinIsProbedForCatalogCandidate() {
        let availability = LanguageServerLocator.resolve(
            language: language(candidates: ["gopls"]),
            pathEnvironment: "/usr/bin:/bin",
            isExecutableFile: { $0 == "/Users/test/go/bin/gopls" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/Users/test/go/bin/gopls"))
    }

    /// An explicit `PATH` entry is probed before the well-known directories, so
    /// user shims (pyenv/asdf) keep precedence over brew.
    @Test func pathEntriesPrecedeWellKnownDirectories() {
        let availability = LanguageServerLocator.resolve(
            language: language(binaryName: "gopls"),
            pathEnvironment: "/custom/bin",
            isExecutableFile: { $0 == "/custom/bin/gopls" || $0 == "/opt/homebrew/bin/gopls" },
            homeDirectory: home
        )

        #expect(availability == .available(executablePath: "/custom/bin/gopls"))
    }

    /// The search list is `PATH` entries first, then well-known directories,
    /// with a directory already on `PATH` not probed twice.
    @Test func searchDirectoriesOrderAndDeduplication() {
        let directories = LanguageServerLocator.searchDirectories(
            pathEnvironment: "/opt/homebrew/bin:/usr/bin",
            homeDirectory: home
        )

        #expect(directories.prefix(2) == ["/opt/homebrew/bin", "/usr/bin"])
        #expect(directories.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(directories.contains("/Users/test/.cargo/bin"))
        #expect(directories.contains("/Users/test/go/bin"))
        #expect(directories.contains("/Users/test/.local/bin"))
    }
}

