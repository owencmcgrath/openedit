import Foundation
import OpenEditConfig

/// Outcome of checking whether a document's configured language server can be
/// launched (ARCHITECTURE.md 5.6). This is the single result both #7 (the
/// missing-LSP notification) and #6 (the process pool) consult for one open
/// event, so a single open can never both warn about a missing server and try
/// to spawn it.
public enum LanguageServerAvailability: Equatable, Sendable {
    /// The executable was found and may be launched. Carries the resolved path
    /// so #6 can spawn exactly what was checked, without re-resolving.
    case available(executablePath: String)

    /// The language configures a server (`binaryName` and/or `lspPath`) but the
    /// executable could not be found. #7 posts its informational notice; #6
    /// must not attempt a launch.
    case missing

    /// No `binaryName` in the config: highlighting-only, no LSP, no notice
    /// (ARCHITECTURE.md 5.2).
    case highlightingOnly
}
