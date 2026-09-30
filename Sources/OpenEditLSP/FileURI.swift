import Foundation

/// `file:` URI conversions for the LSP wire format. LSP documents are
/// addressed by URI strings; OpenEdit documents by `URL`. `URL.absoluteString`
/// already percent-encodes exactly what the spec expects for file URIs
/// (spaces as `%20`, non-ASCII as UTF-8 percent escapes), so this is a thin
/// guard against the empty/degenerate cases rather than an encoder.
public enum FileURI {
    /// LSP URI for a file path, or nil when the URL is not a file URL
    /// (untitled documents have none and are simply not LSP-served).
    public static func make(from url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return url.absoluteString
    }

    /// File URL for an LSP `file:` URI, or nil for other schemes.
    public static func fileURL(for uri: String) -> URL? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url
    }
}
