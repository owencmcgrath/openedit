import Foundation

/// Where a CLI-initiated open wants its document placed (ARCHITECTURE.md 5.1).
///
/// The CLI cannot send flags to an already-running instance (`--args` are
/// ignored, and `-n` would force a second process), so the opt-out travels as
/// the host of an `openedit://` URL instead. A plain file URL — from `open -a`,
/// Finder, or a launch argument — always means `.reuseExistingWindow`, the
/// default.
public enum OpenIntent: Equatable, Sendable {
    /// Tab the file into the frontmost document window, or open a new window
    /// when there is none (§5.1).
    case reuseExistingWindow
    /// Always open a fresh window, regardless of what is already on screen.
    case newWindow
}

/// The host segments the custom URL scheme uses for each intent.
public enum OpenURLScheme {
    public static let scheme = "openedit"
    public static let newWindowHost = "new-window"
    public static let reuseWindowHost = "reuse-window"

    /// The query-item name carrying one absolute file path; repeated once per
    /// file so a single URL can open several files.
    public static let pathQueryItemName = "path"
}

/// A parsed custom-scheme open request: the files to open and where they go.
public struct OpenRequest: Equatable, Sendable {
    public let fileURLs: [URL]
    public let intent: OpenIntent

    public init(fileURLs: [URL], intent: OpenIntent) {
        self.fileURLs = fileURLs
        self.intent = intent
    }
}

/// Parses the `openedit://` URLs the CLI shim uses to carry an explicit intent
/// (ARCHITECTURE.md 5.1). Anything that is not a well-formed `openedit://`
/// request returns `nil`; the app treats such URLs (notably plain file URLs)
/// as the default `.reuseExistingWindow` open.
public enum OpenURLInterpreter {
    public static func interpret(_ url: URL) -> OpenRequest? {
        guard url.scheme?.lowercased() == OpenURLScheme.scheme else { return nil }

        let intent: OpenIntent
        switch url.host?.lowercased() {
        case OpenURLScheme.newWindowHost:
            intent = .newWindow
        case OpenURLScheme.reuseWindowHost:
            intent = .reuseExistingWindow
        default:
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let fileURLs = (components.queryItems ?? [])
            .filter { $0.name == OpenURLScheme.pathQueryItemName }
            .compactMap(\.value)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }

        guard !fileURLs.isEmpty else { return nil }
        return OpenRequest(fileURLs: fileURLs, intent: intent)
    }
}

/// The resolved placement for one document open.
public enum OpenPlacement: Equatable, Sendable {
    case reuseExistingWindow
    case newWindow
}

/// Pure routing decision (ARCHITECTURE.md 5.1): given what the caller asked for
/// and whether a reusable document window exists, where does the document go?
/// Kept Foundation-only so the app's open routing is unit-testable without a
/// window server.
public enum OpenPlacementRouter {
    public static func placement(
        intent: OpenIntent,
        hasReusableWindow: Bool
    ) -> OpenPlacement {
        switch intent {
        case .reuseExistingWindow:
            return hasReusableWindow ? .reuseExistingWindow : .newWindow
        case .newWindow:
            return .newWindow
        }
    }
}
