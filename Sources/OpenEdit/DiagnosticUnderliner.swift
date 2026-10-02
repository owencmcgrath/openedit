import AppKit
import OpenEditLSP

/// Draws diagnostics as severity-colored underlines (ARCHITECTURE.md 5.9).
///
/// Underlines are applied as *temporary* layout-manager attributes, not text
/// storage attributes: they never enter `NSTextStorage`, so they cannot affect
/// syntax colors, undo, the change count, or find/selection styling — the same
/// separation the highlighter maintains for its attribute writes. Colors are
/// dynamic system colors, so light/dark follows the appearance (5.8).
enum DiagnosticUnderliner {
    /// Severity → dynamic underline color. Errors are also drawn thicker.
    static func color(for severity: Diagnostic.Severity) -> NSColor {
        switch severity {
        case .error: return .systemRed
        case .warning: return .systemOrange
        case .information: return .systemBlue
        case .hint: return .secondaryLabelColor
        }
    }

    static func underlineStyle(for severity: Diagnostic.Severity) -> NSUnderlineStyle {
        severity == .error ? .thick : .single
    }

    /// Replace every diagnostic underline on `layoutManager` with `diagnostics`.
    /// `textLength` bounds the sweep used to clear the previous set.
    static func apply(
        _ diagnostics: [RenderableDiagnostic],
        to layoutManager: NSLayoutManager,
        textLength: Int
    ) {
        let wholeDocument = NSRange(location: 0, length: max(0, textLength))
        if wholeDocument.length > 0 {
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: wholeDocument)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: wholeDocument)
        }

        for diagnostic in diagnostics {
            var range = diagnostic.range
            if range.length == 0 {
                // A point diagnostic: underline the character at the point when
                // one exists, otherwise there is nothing visible to draw.
                guard range.location < textLength else { continue }
                range.length = 1
            }
            guard NSMaxRange(range) <= textLength else { continue }
            layoutManager.addTemporaryAttributes(
                [
                    .underlineStyle: underlineStyle(for: diagnostic.severity).rawValue,
                    .underlineColor: color(for: diagnostic.severity),
                ],
                forCharacterRange: range
            )
        }
    }
}
