import AppKit

/// Maps tree-sitter highlight capture names to AppKit *dynamic* system colors
/// (ARCHITECTURE.md 5.8). Dynamic colors resolve at draw time for the current
/// appearance, so highlighting tracks Light/Dark Mode with no extra code and no
/// custom theme engine.
///
/// Capture names come from each grammar's `highlights.scm` and are dotted
/// (`function.method`, `string.escape`, …). A name with no exact entry falls
/// back to its longest prefix, and an unmatched name stays uncolored — the text
/// keeps the dynamic default label color.
public struct SyntaxTheme: Sendable {
    public typealias ColorFactory = @Sendable () -> NSColor

    private let colorsByCapture: [String: ColorFactory]

    public init(colorsByCapture: [String: ColorFactory]) {
        self.colorsByCapture = colorsByCapture
    }

    /// The app's only theme: system semantic colors, resolved dynamically.
    public static let system = SyntaxTheme(colorsByCapture: [
        "keyword": { .systemPink },
        "keyword.operator": { .secondaryLabelColor },
        "keyword.function": { .systemPink },
        "keyword.return": { .systemPink },

        "string": { .systemRed },
        "string.escape": { .systemOrange },
        "string.special": { .systemOrange },
        "escape": { .systemOrange },

        "number": { .systemBlue },
        "boolean": { .systemOrange },

        "comment": { .secondaryLabelColor },
        "comment.documentation": { .secondaryLabelColor },

        "function": { .systemIndigo },
        "function.method": { .systemIndigo },
        "function.call": { .systemIndigo },
        "constructor": { .systemIndigo },

        "type": { .systemPurple },
        "type.builtin": { .systemPurple },
        "module": { .systemTeal },
        "namespace": { .systemTeal },

        "constant": { .systemOrange },
        "constant.builtin": { .systemOrange },
        "variable.builtin": { .systemOrange },
        "variable.parameter": { .systemTeal },

        "property": { .labelColor },
        "field": { .labelColor },
        "variable": { .labelColor },
        "parameter": { .labelColor },
        "label": { .systemBlue },

        "operator": { .secondaryLabelColor },
        "punctuation": { .secondaryLabelColor },
        "punctuation.bracket": { .labelColor },
        "punctuation.delimiter": { .secondaryLabelColor },

        "tag": { .systemPink },
        "attribute": { .systemOrange },
        "annotation": { .systemOrange }
    ])

    /// The color for a capture name, or `nil` to leave the token at the dynamic
    /// default label color.
    public func color(forCapture captureName: String) -> NSColor? {
        var candidate = captureName
        while true {
            if let factory = colorsByCapture[candidate] {
                return factory()
            }
            guard let lastDot = candidate.lastIndex(of: ".") else { return nil }
            candidate = String(candidate[..<lastDot])
        }
    }
}
