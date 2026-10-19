import Foundation

/// `textDocument/hover` result → displayable plain text (ARCHITECTURE.md 5.5).
/// The protocol allows `contents` as a string, a `MarkupContent`
/// (`{ kind, value }`), or an array of either; OpenEdit renders the text plain
/// (no Markdown engine in v1), joining array entries with blank lines.
public enum LSPHover {
    /// The hover text from a request result, or nil when empty/null.
    public static func plainText(from result: JSONValue?) -> String? {
        guard let contents = result?["contents"] else { return nil }
        let text = plainText(fromContents: contents)
        return text.isEmpty ? nil : text
    }

    private static func plainText(fromContents contents: JSONValue) -> String {
        switch contents {
        case let .string(value):
            return value
        case let .object(object):
            // MarkupContent: prefer `value`; `kind` ("plaintext"/"markdown")
            // is ignored because rendering is plain text either way.
            return object["value"]?.stringValue ?? ""
        case let .array(entries):
            return entries
                .map(plainText(fromContents:))
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        default:
            return ""
        }
    }
}
