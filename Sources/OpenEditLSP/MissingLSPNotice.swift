import Foundation
import OpenEditConfig

/// The informational notice shown when a configured language server is not
/// installed (ARCHITECTURE.md 5.6). Pure value so the exact wording — in
/// particular that the body *is* the configured `installCommand`, verbatim —
/// is testable without `UserNotifications`.
public struct MissingLSPNotice: Equatable, Sendable {
    public let title: String

    /// Exactly the configured `installCommand` when present; the app never runs
    /// it, only displays it.
    public let body: String

    public init(language: ResolvedLanguage) {
        let name = Self.displayName(for: language.languageID)
        title = "\(name) language server not installed"

        if let installCommand = language.installCommand, !installCommand.isEmpty {
            body = installCommand
        } else {
            // `binaryName` without `installCommand` is valid per 5.2; still tell
            // the user what was looked for rather than showing an empty body.
            let binaryName = language.binaryName ?? "the language server"
            body = "\(binaryName) was not found. Install it to enable language features."
        }
    }

    /// "python" → "Python". The registry has no display-name field (5.2), so the
    /// stable `languageId` is the source; first-letter capitalization reads
    /// acceptably for the bundled IDs and user extensions.
    public static func displayName(for languageID: String) -> String {
        guard let first = languageID.first else { return languageID }
        return first.uppercased() + languageID.dropFirst()
    }
}
