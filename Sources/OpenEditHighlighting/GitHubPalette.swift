import AppKit

/// The GitHub theme's colors for the editor surface and its tokens
/// (ARCHITECTURE.md 5.8) — `primer/github-vscode-theme` 6.3.5, whose Light
/// Default and Dark Default palettes are built from `@primer/primitives`
/// 7.10.0. Every color is *dynamic*: it carries the Light Default and Dark
/// Default hex value and resolves at draw time for the current appearance, so
/// the editor tracks Light/Dark Mode with no extra code. Names mirror the VS
/// Code theme keys (or scale stop) each color comes from.
public enum GitHubPalette {
    // MARK: Editor surface (the theme's `colors` section)

    /// `editor.background` — canvas.default: #ffffff light / #0d1117 dark.
    public static let editorBackground = githubColor(light: 0xFFFFFF, dark: 0x0D1117)

    /// `editor.foreground` — fg.default: #1f2328 light / #e6edf3 dark.
    public static let foreground = githubColor(light: 0x1F2328, dark: 0xE6EDF3)

    /// `editorCursor.foreground` — accent.fg: #0969da light / #2f81f7 dark.
    public static let cursor = githubColor(light: 0x0969DA, dark: 0x2F81F7)

    /// `editor.selectionBackground` — accent.fg at 0.2 alpha in both
    /// appearances.
    public static let selection = githubColor(light: 0x0969DA, dark: 0x2F81F7, alpha: 0.2)

    /// `editorLineNumber.foreground` — scale.gray[4]: #8c959f light /
    /// #6e7681 dark.
    public static let lineNumber = githubColor(light: 0x8C959F, dark: 0x6E7681)

    /// `editorLineNumber.activeForeground` — fg.default: the line(s) the
    /// selection touches draw their number in the regular foreground.
    public static let lineNumberActive = foreground

    // MARK: Tokens (the theme's `tokenColors` section)

    /// `keyword` (and `storage`) — scale.red[5] / scale.red[3]: #cf222e /
    /// #ff7b72. Escape sequences ride the same stop through the theme's
    /// `constant.character` selector.
    public static let keyword = githubColor(light: 0xCF222E, dark: 0xFF7B72)

    /// `string` — scale.blue[8] / scale.blue[1]: #0a3069 / #a5d6ff.
    public static let string = githubColor(light: 0x0A3069, dark: 0xA5D6FF)

    /// `constant` — scale.blue[6] / scale.blue[2]: #0550ae / #79c0ff. Also
    /// serves `variable.language` (self, this) and `entity.other.attribute-name`,
    /// which the theme resolves to the same scale stop.
    public static let constant = githubColor(light: 0x0550AE, dark: 0x79C0FF)

    /// `comment` — scale.gray[5] / scale.gray[3]: #6e7781 / #8b949e.
    public static let comment = githubColor(light: 0x6E7781, dark: 0x8B949E)

    /// `entity.name.function` — scale.purple[5] / scale.purple[2]: #8250df /
    /// #d2a8ff.
    public static let function = githubColor(light: 0x8250DF, dark: 0xD2A8FF)

    /// `entity.name` and `variable` — scale.orange[6] / scale.orange[2]:
    /// #953800 / #ffa657. Types, namespaces, and plain variables all share it.
    public static let type = githubColor(light: 0x953800, dark: 0xFFA657)

    /// `entity.name.tag` — scale.green[6] / scale.green[1]: #116329 / #7ee787.
    public static let tag = githubColor(light: 0x116329, dark: 0x7EE787)
}

/// One GitHub palette entry across appearances: resolves to the light hex
/// under Aqua (including its high-contrast variant) and the dark hex under
/// darkAqua. `alpha` carries the theme's translucent surfaces (the selection).
private func githubColor(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(name: nil, dynamicProvider: { appearance in
        let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    })
}