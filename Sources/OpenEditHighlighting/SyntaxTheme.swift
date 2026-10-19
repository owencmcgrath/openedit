import AppKit

/// Maps tree-sitter highlight capture names to the GitHub theme's token
/// colors (ARCHITECTURE.md 5.8). The palette is GitHub's own editor theme
/// (`primer/github-vscode-theme`, Light Default + Dark Default — see
/// `GitHubPalette`), rendered as *dynamic* `NSColor`s that resolve at draw
/// time for the current appearance, so highlighting tracks Light/Dark Mode
/// with no extra code and no custom theme engine.
///
/// Capture names come from each grammar's `highlights.scm` and are dotted
/// (`function.method`, `string.escape`, …). A name with no exact entry falls
/// back to its longest prefix, and an unmatched name stays uncolored — the
/// text keeps the theme's default editor foreground (`foreground`).
public struct SyntaxTheme: Sendable {
    public typealias ColorFactory = @Sendable () -> NSColor

    private let colorsByCapture: [String: ColorFactory]
    private let foregroundFactory: ColorFactory

    /// The color for text outside any capture: the GitHub editor foreground
    /// (`editor.foreground`, #1f2328 light / #e6edf3 dark).
    public var foreground: NSColor { foregroundFactory() }

    public init(colorsByCapture: [String: ColorFactory], foreground: @escaping ColorFactory) {
        self.colorsByCapture = colorsByCapture
        self.foregroundFactory = foreground
    }

    /// The app's only theme: GitHub's Light/Dark Default token colors. Each
    /// group's comment names the VS Code scope selector it mirrors.
    public static let github = SyntaxTheme(
        colorsByCapture: [
            // `keyword` (and `storage`). Operators are `keyword.operator`, and
            // escape sequences are `constant.character`, which the theme
            // resolves to the same red.
            "keyword": { GitHubPalette.keyword },
            "keyword.operator": { GitHubPalette.keyword },
            "keyword.function": { GitHubPalette.keyword },
            "keyword.return": { GitHubPalette.keyword },

            // `string`
            "string": { GitHubPalette.string },
            "string.escape": { GitHubPalette.keyword },
            "string.special": { GitHubPalette.string },
            "escape": { GitHubPalette.keyword },

            // `constant` (and `support`) — numbers, booleans, builtin
            // constants; builtin types ride the theme's `support` selector,
            // which resolves to the same blue stop.
            "number": { GitHubPalette.constant },
            "boolean": { GitHubPalette.constant },

            // `comment`
            "comment": { GitHubPalette.comment },
            "comment.documentation": { GitHubPalette.comment },

            // `entity.name.function` — definitions and calls share the purple
            "function": { GitHubPalette.function },
            "function.method": { GitHubPalette.function },
            "function.call": { GitHubPalette.function },
            "constructor": { GitHubPalette.function },

            // `entity.name` (types, namespaces) and `variable` share the orange
            "type": { GitHubPalette.type },
            "module": { GitHubPalette.type },
            "namespace": { GitHubPalette.type },

            "constant.builtin": { GitHubPalette.constant },
            "type.builtin": { GitHubPalette.constant }, // `support`: int, str
            "variable.builtin": { GitHubPalette.constant }, // `variable.language`: self, this
            "variable": { GitHubPalette.type },
            "variable.parameter": { GitHubPalette.foreground }, // `variable.parameter.function`
            "parameter": { GitHubPalette.foreground },
            "property": { GitHubPalette.foreground }, // `variable.other`
            "field": { GitHubPalette.foreground },
            "label": { GitHubPalette.type },

            "operator": { GitHubPalette.keyword },
            "punctuation": { GitHubPalette.foreground },
            "punctuation.bracket": { GitHubPalette.foreground },
            "punctuation.delimiter": { GitHubPalette.foreground },

            "tag": { GitHubPalette.tag }, // `entity.name.tag`
            "attribute": { GitHubPalette.constant }, // `entity.other.attribute-name`
            "annotation": { GitHubPalette.function } // decorators render like functions
        ],
        foreground: { GitHubPalette.foreground }
    )

    /// The color for a capture name, or `nil` to leave the token at the
    /// theme's default foreground.
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
