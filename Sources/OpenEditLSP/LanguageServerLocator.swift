import Foundation
import OpenEditConfig

/// Resolves a configured language server to an executable on disk
/// (ARCHITECTURE.md 5.6).
///
/// The `PATH` used is the GUI app's *effective* `PATH` — the environment the
/// process actually inherited — not a login shell's `PATH`. Spawning
/// `/bin/zsh -lic 'echo $PATH'` to guess an interactive shell's `PATH` would
/// make availability depend on the user's dotfiles and would run a shell on
/// every open; the architecture calls for the process environment instead.
///
/// Pure and injectable: the filesystem probe is a closure so tests can drive
/// installed / missing / invalid-literal-path cases without touching the real
/// machine.
public enum LanguageServerLocator {
    /// Standard locations to fall back on when the process environment has no
    /// `PATH` at all (some launch contexts strip it). Mirrors the launchd
    /// default plus the common Homebrew/local prefixes, but is only consulted
    /// when `PATH` is genuinely absent — never to override a present `PATH`.
    public static let fallbackPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolve `language` against `pathEnvironment` (a `PATH`-style string).
    public static func resolve(
        language: ResolvedLanguage,
        pathEnvironment: String?,
        isExecutableFile: (String) -> Bool
    ) -> LanguageServerAvailability {
        // No binary name means highlighting-only, regardless of any other
        // field — the loader already rejects `lspPath` without `binaryName`.
        guard let binaryName = language.binaryName, !binaryName.isEmpty else {
            return .highlightingOnly
        }

        // A literal `lspPath` overrides the PATH lookup and is authoritative:
        // if it is set but not executable, that is a miss, not a fall-through
        // to PATH (ARCHITECTURE.md 5.2).
        if let lspPath = language.lspPath, !lspPath.isEmpty {
            return isExecutableFile(lspPath) ? .available(executablePath: lspPath) : .missing
        }

        let path = pathEnvironment ?? fallbackPath
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(binaryName)
                .path
            if isExecutableFile(candidate) {
                return .available(executablePath: candidate)
            }
        }
        return .missing
    }

    /// Convenience over `resolve(language:pathEnvironment:isExecutableFile:)`
    /// using the process environment and the real filesystem.
    public static func resolve(
        language: ResolvedLanguage,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LanguageServerAvailability {
        resolve(
            language: language,
            pathEnvironment: environment["PATH"],
            isExecutableFile: { fileManager.isExecutableFile(atPath: $0) }
        )
    }
}
