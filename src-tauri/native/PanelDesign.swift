import AppKit

/// Shared design tokens for the native panels (LauncherPanel,
/// ClipboardPanel; ActionPanel's card chrome keeps its own CardTheme layer).
///
/// One source of truth for panel chrome, pills, selection capsules and row
/// content geometry — panels never hand-pick spacing numbers again. Values
/// are in points; every panel renders at the same width so the metrics
/// transfer exactly.
enum PanelDesign {
    // MARK: panel chrome

    static let panelWidth: CGFloat = 520
    static let panelCornerRadius: CGFloat = 14
    /// Panel-level horizontal margin: search field, filter/tab pill row,
    /// footer text — one shared left line down every panel.
    static let sideInset: CGFloat = 12
    static let searchHeight: CGFloat = 26

    // MARK: pills (filters/tabs) vs chips (inline content)

    static let pillHeight: CGFloat = 24
    /// Filter/tab pills read as capsules at their full height.
    static let pillCornerRadius: CGFloat = 12
    /// Inline content chips (folder grid) stay squarer.
    static let chipCornerRadius: CGFloat = 6

    // MARK: row selection capsule

    static let rowCapsuleInsetX: CGFloat = 6
    static let rowCapsuleInsetY: CGFloat = 2
    static let rowCapsuleRadius: CGFloat = 7

    // MARK: row content geometry
    //
    // icon pinned to rowContentLeading; text starts after rowIconToText;
    // text trailing never passes rowContentTrailing. Inside the capsule
    // (inset rowCapsuleInsetX) the content is padded symmetrically:
    //   (rowContentLeading - rowCapsuleInsetX) == rowIconToText
    //   == (rowContentTrailing - rowCapsuleInsetX)
    // → 10pt everywhere at the current values.

    static let rowContentLeading: CGFloat = 16
    static let rowContentTrailing: CGFloat = 16
    static let rowIconSize: CGFloat = 24
    static let rowIconToText: CGFloat = 10
}
