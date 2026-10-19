import Foundation

/// One diagnostic from `textDocument/publishDiagnostics` (ARCHITECTURE.md
/// 5.9), in the units the wire uses. Rendering to AppKit attributes happens in
/// the app target; this type is the parsed, validated model.
public struct Diagnostic: Equatable, Sendable {
    /// LSP severities: 1 Error, 2 Warning, 3 Information, 4 Hint. Unknown
    /// values are treated as `.information`.
    public enum Severity: Int, Sendable, CaseIterable {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }

    public let range: LSPRange
    public let severity: Severity
    public let message: String
    public let source: String?

    public init(range: LSPRange, severity: Severity, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }

    /// Parse one diagnostic entry. Returns nil when required fields are
    /// missing or malformed — a bad entry is skipped, never fatal.
    public static func parse(_ json: JSONValue) -> Diagnostic? {
        guard let rangeJSON = json["range"],
              let start = position(from: rangeJSON["start"]),
              let end = position(from: rangeJSON["end"]),
              let message = json["message"]?.stringValue
        else { return nil }

        let severity = json["severity"]?.intValue
            .flatMap(Severity.init(rawValue:)) ?? .information
        return Diagnostic(
            range: LSPRange(start: start, end: end),
            severity: severity,
            message: message,
            source: json["source"]?.stringValue
        )
    }

    private static func position(from json: JSONValue?) -> LSPPosition? {
        guard let line = json?["line"]?.intValue, let character = json?["character"]?.intValue else {
            return nil
        }
        return LSPPosition(line: line, character: character)
    }
}

/// A `textDocument/publishDiagnostics` notification's contents.
public struct DiagnosticsPublish: Equatable, Sendable {
    public let uri: String
    /// The document version these diagnostics describe, when the server sends
    /// one (optional in the protocol). Used to reject stale pushes.
    public let version: Int?
    public let diagnostics: [Diagnostic]

    public init(uri: String, version: Int?, diagnostics: [Diagnostic]) {
        self.uri = uri
        self.version = version
        self.diagnostics = diagnostics
    }

    /// Parse `params` of a publishDiagnostics notification. Returns nil when
    /// the URI is absent.
    public static func parse(params: JSONValue?) -> DiagnosticsPublish? {
        guard let uri = params?["uri"]?.stringValue else { return nil }
        let diagnostics = (params?["diagnostics"]?.arrayValue ?? []).compactMap(Diagnostic.parse)
        return DiagnosticsPublish(
            uri: uri,
            version: params?["version"]?.intValue,
            diagnostics: diagnostics
        )
    }
}

/// A diagnostic with its range resolved and validated against a document's
/// current text, ready for AppKit attribute application.
public struct RenderableDiagnostic: Equatable {
    public let range: NSRange
    public let severity: Diagnostic.Severity
    public let message: String

    public init(range: NSRange, severity: Diagnostic.Severity, message: String) {
        self.range = range
        self.severity = severity
        self.message = message
    }
}

/// Holds the diagnostics for one open document (ARCHITECTURE.md 5.9).
///
/// Staleness rule: a publish is accepted only while the document has not been
/// edited since (and, when the server sends a `version`, only when it matches
/// the version the client last sent). An edit invalidates the current set —
/// underlines clear until the server re-publishes — so diagnostics are never
/// shown against text they no longer describe ([Decided] checkpoints: no
/// diagnostics for closed or changed-version documents).
public struct DocumentDiagnostics: Equatable {
    public private(set) var diagnostics: [Diagnostic] = []
    public private(set) var acceptedVersion: Int?

    public init() {}

    public mutating func accept(_ publish: DiagnosticsPublish, currentVersion: Int) -> Bool {
        if let version = publish.version, version != currentVersion {
            return false // stale push for an older/newer document version
        }
        diagnostics = publish.diagnostics
        acceptedVersion = currentVersion
        return true
    }

    /// The document changed: drop the current set until the server republishes.
    public mutating func invalidate() {
        diagnostics = []
        acceptedVersion = nil
    }

    /// Diagnostics whose ranges map into `text`, validated and sorted by
    /// location so rendering order is stable.
    public func renderable(in text: NSString) -> [RenderableDiagnostic] {
        diagnostics.compactMap { diagnostic in
            guard let range = diagnostic.range.nsRange(in: text) else { return nil }
            return RenderableDiagnostic(
                range: range,
                severity: diagnostic.severity,
                message: diagnostic.message
            )
        }
        .sorted { $0.range.location < $1.range.location }
    }

    /// The diagnostic containing `utf16Offset`, for tooltip display: the
    /// nearest zero-length diagnostic at the offset counts as containing it.
    public func diagnostic(atUTF16Offset offset: Int, in text: NSString) -> RenderableDiagnostic? {
        let renderable = renderable(in: text)
        // Prefer an exact containment; a zero-length range matches its offset.
        if let containing = renderable.first(where: {
            offset >= $0.range.location && offset < NSMaxRange($0.range)
        }) {
            return containing
        }
        return renderable.first {
            $0.range.length == 0 && $0.range.location == offset
        }
    }
}
