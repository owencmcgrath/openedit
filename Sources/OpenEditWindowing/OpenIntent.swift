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

/// What the URL asks the app to do. `open` carries one or more file targets;
/// `reopen` walks the last-closed stack and has no target of its own.
public enum OpenRequestAction: Equatable, Sendable {
    case open
    case reopen
}

/// One 1-based text position. A nil column means "the start/end of the line"
/// depending on which endpoint it is; the app resolves it against the live
/// document. Columns count UTF-16 code units, matching AppKit's selection APIs.
public struct TextPosition: Equatable, Sendable {
    public let line: Int
    public let column: Int?

    public init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }
}

/// A resolved selection from the CLI (ARCHITECTURE.md 5.1). `start == end` is a
/// caret and always carries a concrete column; otherwise a nil column on the
/// start endpoint means "start of that line" and on the end endpoint "end of
/// that line (excluding its newline)". The app converts the pair to an
/// `NSRange` via `TextSelectionResolver`.
public struct TextSelection: Equatable, Sendable {
    public let start: TextPosition
    public let end: TextPosition

    public init(start: TextPosition, end: TextPosition) {
        self.start = start
        self.end = end
    }
}

/// One file the URL asks to open, plus its optional jump/selection position.
public struct OpenTarget: Equatable, Sendable {
    public let fileURL: URL
    public let selection: TextSelection?

    public init(fileURL: URL, selection: TextSelection? = nil) {
        self.fileURL = fileURL
        self.selection = selection
    }
}

public struct OpenWindowSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct OpenWindowPosition: Equatable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Line-ending choices exposed by `--eol`.
public enum OpenLineEnding: String, Equatable, Sendable {
    case lf
    case crlf
}

/// Per-open/per-document options carried by the CLI URL (ARCHITECTURE.md 5.1).
/// Defaults preserve the behavior of a bare `openedit file`.
public struct OpenDocumentOptions: Equatable, Sendable {
    public var readOnly = false
    public var encoding: String?
    public var lineEnding: OpenLineEnding?
    public var tabSize: Int?
    public var expandTabs = false
    public var wrapsLines: Bool?
    public var highlighting = true
    public var forcedLanguage: String?
    public var grammarDirectory: String?
    public var configPath: String?
    public var usesBundledConfigOnly = false
    public var lspEnabled = true
    public var autodetectServers = true
    public var lspLanguage: String?
    public var lspServerOverrides: [String: String] = [:]
    public var lspLogPath: String?
    public var watchesFile = true
    public var watchDebounceMilliseconds = 0
    public var isScratch = false
    public var waitToken: String?
    public var printsFilename = false
    public var background = false
    public var windowSize: OpenWindowSize?
    public var windowPosition: OpenWindowPosition?
    public var logLevel: String?
    public var logFilePath: String?
    public var debug = false

    public init() {}
}

/// The host segments the custom URL scheme uses for each intent.
public enum OpenURLScheme {
    public static let scheme = "openedit"
    public static let newWindowHost = "new-window"
    public static let reuseWindowHost = "reuse-window"

    /// The query-item name carrying one absolute file path; repeated once per
    /// file so a single URL can open several files. `line`/`col` items that
    /// follow a path apply to that target.
    public static let pathQueryItemName = "path"
    public static let lineQueryItemName = "line"
    public static let colQueryItemName = "col"
    public static let actionQueryItemName = "action"
    public static let readOnlyQueryItemName = "readonly"
    public static let encodingQueryItemName = "encoding"
    public static let eolQueryItemName = "eol"
    public static let tabSizeQueryItemName = "tabsize"
    public static let expandTabsQueryItemName = "expand-tabs"
    public static let wrapQueryItemName = "wrap"
    public static let highlightingQueryItemName = "highlighting"
    public static let languageQueryItemName = "language"
    public static let grammarDirectoryQueryItemName = "grammar-dir"
    public static let configQueryItemName = "config"
    public static let noConfigQueryItemName = "no-config"
    public static let lspQueryItemName = "lsp"
    public static let autodetectQueryItemName = "autodetect"
    public static let lspLanguageQueryItemName = "lsp-language"
    public static let lspServerQueryItemName = "lsp-server"
    public static let lspLogQueryItemName = "lsp-log"
    public static let watcherQueryItemName = "watcher"
    public static let watchDebounceQueryItemName = "watch-debounce"
    public static let scratchQueryItemName = "scratch"
    public static let waitQueryItemName = "wait"
    public static let printFilenameQueryItemName = "print-filename"
    public static let backgroundQueryItemName = "background"
    public static let sizeQueryItemName = "size"
    public static let positionQueryItemName = "position"
    public static let logLevelQueryItemName = "log-level"
    public static let logFileQueryItemName = "log-file"
    public static let debugQueryItemName = "debug"
}

/// A parsed custom-scheme open request: the files to open, where they go, and
/// the per-open options that could not travel as launch arguments.
public struct OpenRequest: Equatable, Sendable {
    public let targets: [OpenTarget]
    public let intent: OpenIntent
    public let action: OpenRequestAction
    public let options: OpenDocumentOptions

    public init(
        targets: [OpenTarget],
        intent: OpenIntent,
        action: OpenRequestAction = .open,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) {
        self.targets = targets
        self.intent = intent
        self.action = action
        self.options = options
    }

    /// Compatibility initializer for callers that only have bare file URLs.
    public init(
        fileURLs: [URL],
        intent: OpenIntent,
        action: OpenRequestAction = .open,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) {
        self.init(
            targets: fileURLs.map { OpenTarget(fileURL: $0) },
            intent: intent,
            action: action,
            options: options
        )
    }

    public var fileURLs: [URL] { targets.map(\.fileURL) }
}

/// Parses the `openedit://` URLs the CLI shim uses to carry an explicit intent
/// and per-open options (ARCHITECTURE.md 5.1). Anything that is not a
/// well-formed `openedit://` request returns `nil`; the app treats such URLs
/// (notably plain file URLs) as the default `.reuseExistingWindow` open.
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

        var targets: [MutableTarget] = []
        var options = OpenDocumentOptions()
        var action = OpenRequestAction.open
        var isValid = true

        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name {
            case OpenURLScheme.pathQueryItemName:
                guard !value.isEmpty else { isValid = false; continue }
                targets.append(
                    MutableTarget(fileURL: URL(fileURLWithPath: value).standardizedFileURL)
                )
            case OpenURLScheme.lineQueryItemName:
                guard !targets.isEmpty, let spec = LineSpec(value) else { isValid = false; continue }
                targets[targets.count - 1].lineSpec = spec
            case OpenURLScheme.colQueryItemName:
                guard !targets.isEmpty, let spec = LineSpec(value) else { isValid = false; continue }
                targets[targets.count - 1].colSpec = spec
            case OpenURLScheme.actionQueryItemName:
                guard value == "reopen" else { isValid = false; continue }
                action = .reopen
            case OpenURLScheme.readOnlyQueryItemName:
                options.readOnly = parseBool(value) ?? false
            case OpenURLScheme.encodingQueryItemName:
                options.encoding = value.isEmpty ? nil : value
            case OpenURLScheme.eolQueryItemName:
                guard let lineEnding = OpenLineEnding(rawValue: value.lowercased()) else {
                    isValid = false
                    continue
                }
                options.lineEnding = lineEnding
            case OpenURLScheme.tabSizeQueryItemName:
                guard let tabSize = Int(value), tabSize > 0 else { isValid = false; continue }
                options.tabSize = tabSize
            case OpenURLScheme.expandTabsQueryItemName:
                options.expandTabs = parseBool(value) ?? false
            case OpenURLScheme.wrapQueryItemName:
                options.wrapsLines = parseBool(value)
            case OpenURLScheme.highlightingQueryItemName:
                options.highlighting = parseBool(value) ?? true
            case OpenURLScheme.languageQueryItemName:
                options.forcedLanguage = value.isEmpty ? nil : value
            case OpenURLScheme.grammarDirectoryQueryItemName:
                options.grammarDirectory = value.isEmpty ? nil : value
            case OpenURLScheme.configQueryItemName:
                options.configPath = value.isEmpty ? nil : value
            case OpenURLScheme.noConfigQueryItemName:
                options.usesBundledConfigOnly = parseBool(value) ?? false
            case OpenURLScheme.lspQueryItemName:
                options.lspEnabled = parseBool(value) ?? true
            case OpenURLScheme.autodetectQueryItemName:
                options.autodetectServers = parseBool(value) ?? true
            case OpenURLScheme.lspLanguageQueryItemName:
                options.lspLanguage = value.isEmpty ? nil : value
            case OpenURLScheme.lspServerQueryItemName:
                guard let separator = value.firstIndex(of: "="),
                      separator != value.startIndex,
                      value.index(after: separator) != value.endIndex
                else {
                    isValid = false
                    continue
                }
                let languageID = String(value[..<separator])
                let path = String(value[value.index(after: separator)...])
                options.lspServerOverrides[languageID] = path
            case OpenURLScheme.lspLogQueryItemName:
                options.lspLogPath = value.isEmpty ? nil : value
            case OpenURLScheme.watcherQueryItemName:
                options.watchesFile = parseBool(value) ?? true
            case OpenURLScheme.watchDebounceQueryItemName:
                guard let milliseconds = Int(value), milliseconds >= 0 else {
                    isValid = false
                    continue
                }
                options.watchDebounceMilliseconds = milliseconds
            case OpenURLScheme.scratchQueryItemName:
                options.isScratch = parseBool(value) ?? false
            case OpenURLScheme.waitQueryItemName:
                options.waitToken = value.isEmpty ? nil : value
            case OpenURLScheme.printFilenameQueryItemName:
                options.printsFilename = parseBool(value) ?? false
            case OpenURLScheme.backgroundQueryItemName:
                options.background = parseBool(value) ?? false
            case OpenURLScheme.sizeQueryItemName:
                options.windowSize = parseSize(value)
                if options.windowSize == nil { isValid = false }
            case OpenURLScheme.positionQueryItemName:
                options.windowPosition = parsePosition(value)
                if options.windowPosition == nil { isValid = false }
            case OpenURLScheme.logLevelQueryItemName:
                options.logLevel = value.isEmpty ? nil : value
            case OpenURLScheme.logFileQueryItemName:
                options.logFilePath = value.isEmpty ? nil : value
            case OpenURLScheme.debugQueryItemName:
                options.debug = parseBool(value) ?? false
            default:
                // Unknown items are ignored so an older app can still consume a
                // newer shim's URL as far as it understands it.
                continue
            }
        }

        if targets.contains(where: { $0.colSpec != nil && $0.lineSpec == nil }) {
            isValid = false
        }
        guard isValid else { return nil }
        if action == .open, targets.isEmpty, !options.isScratch { return nil }

        let resolvedTargets = targets.map { target -> OpenTarget in
            OpenTarget(
                fileURL: target.fileURL,
                selection: makeSelection(
                    lineSpec: target.lineSpec,
                    colSpec: target.colSpec
                )
            )
        }
        return OpenRequest(targets: resolvedTargets, intent: intent, action: action, options: options)
    }

    // MARK: - Position grammar (ARCHITECTURE.md 5.1)

    /// `N` (a single position) or `START-END` (a span), both 1-based. A single
    /// position keeps `end == nil`, so the selection layer can tell a caret
    /// (`file:12`) from an explicit one-line range (`file:12-12`, which selects
    /// the whole line). Returns nil for zero, negatives, inverted ranges, or
    /// anything else.
    private struct LineSpec: Equatable {
        let start: Int
        /// nil for a single `N`; the span's last position (inclusive) otherwise.
        let end: Int?

        /// The raw value was a single `N`, not a `START-END` span.
        var isSinglePosition: Bool { end == nil }

        init?(_ rawValue: String) {
            let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                guard let value = Int(parts[0]), value > 0 else { return nil }
                start = value
                end = nil
            case 2:
                guard let start = Int(parts[0]), let end = Int(parts[1]),
                      start > 0, end > 0, start <= end
                else { return nil }
                self.start = start
                self.end = end
            default:
                return nil
            }
        }
    }

    /// The CLI grammar (ARCHITECTURE.md 5.1): a single position — `file:N[:COL]`,
    /// `--line N`, `--col N` — is a caret; two lines or two columns select that
    /// range, and a single column on a line range applies to both endpoints.
    private static func makeSelection(lineSpec: LineSpec?, colSpec: LineSpec?) -> TextSelection? {
        guard let lineSpec else {
            // A column without a line has no anchor; the shim never emits one.
            return nil
        }

        // A caret carries a concrete column — the start of the line when none
        // was given — because a nil column reads as "whole line" to the
        // resolver, which would turn `file:12` into a highlight.
        if lineSpec.isSinglePosition, colSpec?.isSinglePosition ?? true {
            let position = TextPosition(line: lineSpec.start, column: colSpec?.start ?? 1)
            return TextSelection(start: position, end: position)
        }

        return TextSelection(
            start: TextPosition(line: lineSpec.start, column: colSpec?.start),
            end: TextPosition(line: lineSpec.end ?? lineSpec.start, column: colSpec?.end ?? colSpec?.start)
        )
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private static func parseSize(_ value: String) -> OpenWindowSize? {
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0
        else { return nil }
        return OpenWindowSize(width: width, height: height)
    }

    private static func parsePosition(_ value: String) -> OpenWindowPosition? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Int(parts[0]), let y = Int(parts[1])
        else { return nil }
        return OpenWindowPosition(x: x, y: y)
    }

    private struct MutableTarget {
        let fileURL: URL
        var lineSpec: LineSpec?
        var colSpec: LineSpec?
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
