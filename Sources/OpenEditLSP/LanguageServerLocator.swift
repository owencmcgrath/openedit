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
    /// default plus the common Homebrew/local prefixes.
    public static let fallbackPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Directories a GUI-launched app's stripped `PATH` commonly omits, but
    /// where package managers put language servers. Probed *after* the `PATH`
    /// directories, so an explicit `PATH` (e.g. pyenv/asdf shims) still wins;
    /// static, so no shell is spawned per open.
    ///
    /// - `/opt/homebrew/bin` — Homebrew on Apple Silicon
    /// - `/usr/local/bin` — Homebrew on Intel
    /// - `~/.cargo/bin` — rustup (rust-analyzer)
    /// - `~/go/bin` — `go install` (gopls)
    /// - `~/.local/bin` — pipx / user pip (pylsp)
    public static let wellKnownInstallDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.cargo/bin",
        "~/go/bin",
        "~/.local/bin",
    ]

    /// Expand `~` in the well-known directories against `homeDirectory`.
    public static func expandedWellKnownInstallDirectories(homeDirectory: URL) -> [String] {
        wellKnownInstallDirectories.map { directory in
            guard directory.hasPrefix("~/") else { return directory }
            return homeDirectory.appendingPathComponent(String(directory.dropFirst(2))).path
        }
    }

    /// The directories a resolve will actually probe, in order: the `PATH`
    /// entries (or `fallbackPath` when absent), then the well-known install
    /// directories, de-duplicated so a directory already on `PATH` is not
    /// probed twice.
    public static func searchDirectories(pathEnvironment: String?, homeDirectory: URL) -> [String] {
        let path = pathEnvironment ?? fallbackPath
        var directories = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        for directory in expandedWellKnownInstallDirectories(homeDirectory: homeDirectory)
        where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    /// Resolve `language` against `pathEnvironment` (a `PATH`-style string) plus
    /// the well-known install directories.
    ///
    /// Precedence (ARCHITECTURE.md 5.2/5.6): explicit `lspPath` → explicit
    /// `binaryName` → catalog `binaryAlternatives` (probed in order, first hit
    /// wins). Every branch that finds a server yields `.available`; a
    /// configured/catalogued server that is not found yields `.missing`. Only a
    /// language with neither an explicit server nor catalog candidates is
    /// `.highlightingOnly`.
    public static func resolve(
        language: ResolvedLanguage,
        pathEnvironment: String?,
        isExecutableFile: (String) -> Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LanguageServerAvailability {
        // A literal `lspPath` overrides the PATH lookup and is authoritative:
        // if it is set but not executable, that is a miss, not a fall-through
        // to PATH or to catalog candidates (ARCHITECTURE.md 5.2).
        if let lspPath = language.lspPath, !lspPath.isEmpty {
            return isExecutableFile(lspPath) ? .available(executablePath: lspPath) : .missing
        }

        let directories = searchDirectories(pathEnvironment: pathEnvironment, homeDirectory: homeDirectory)

        // Explicit config wins: a configured `binaryName` is the only candidate
        // probed, and its absence is a miss (not an autodetection fallback).
        if let binaryName = language.binaryName, !binaryName.isEmpty {
            if let executablePath = findExecutable(
                named: binaryName,
                directories: directories,
                isExecutableFile: isExecutableFile
            ) {
                return .available(executablePath: executablePath)
            }
            return .missing
        }

        // Catalog autodetection: probe the ordered candidates, first hit wins.
        // All-missing is still a configured-in-spirit server, so it gets the
        // same missing notice keyed by this language's `languageId` (5.6).
        if !language.binaryAlternatives.isEmpty {
            for candidate in language.binaryAlternatives where !candidate.isEmpty {
                if let executablePath = findExecutable(
                    named: candidate,
                    directories: directories,
                    isExecutableFile: isExecutableFile
                ) {
                    return .available(executablePath: executablePath)
                }
            }
            return .missing
        }

        // No explicit server and no catalog candidates: highlighting-only.
        return .highlightingOnly
    }

    /// The first directory holding an executable `binaryName`, or `nil`.
    private static func findExecutable(
        named binaryName: String,
        directories: [String],
        isExecutableFile: (String) -> Bool
    ) -> String? {
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(binaryName)
                .path
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
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
