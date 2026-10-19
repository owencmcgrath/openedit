import CoreFoundation
import Foundation

/// Maps the charset names accepted by `--encoding` to Foundation encodings
/// (ARCHITECTURE.md 5.1). Kept Foundation-only so the shim's names are testable
/// and the app has one place to reject an unknown charset.
public enum OpenTextEncoding {
    /// Resolve an IANA charset name (`UTF-8`, `ISO-8859-1`, `windows-1252`, …)
    /// plus a few common spellings. Returns nil for an unknown name.
    public static func stringEncoding(forName name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf8", "utf-8": return .utf8
        case "utf16", "utf-16": return .utf16
        case "utf16le", "utf-16le": return .utf16LittleEndian
        case "utf16be", "utf-16be": return .utf16BigEndian
        case "ascii", "us-ascii": return .ascii
        case "latin1", "latin-1", "iso-8859-1", "iso8859-1": return .isoLatin1
        case "iso-8859-2", "iso8859-2": return .isoLatin2
        case "windows-1252", "cp1252": return .windowsCP1252
        case "macroman", "macintosh": return .macOSRoman
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }
}
