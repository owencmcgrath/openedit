import Foundation
import OpenEditConfig
import OpenEditLSP

/// The app's one process pool (ARCHITECTURE.md component map: LSP client).
/// Resolves a file's config entry through `DocumentLanguageMapping` and spawns
/// real `Process` transports against `LanguageServerLocator`-approved paths.
enum LanguageServerPool {
    @MainActor static let shared = LSPProcessPool(
        languageResolver: { DocumentLanguageMapping.resolvedLanguage(for: $0) },
        clientFactory: { executablePath in
            LanguageServerClient(transport: ProcessTransport(executablePath: executablePath))
        }
    )
}
