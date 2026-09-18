import AppKit

/// GEOMETRY tokens for the native panels (LauncherPanel, ClipboardPanel):
/// widths, insets, pill/row metrics. Surface APPEARANCE (material, scrim,
/// border, corner-radius role) lives in PanelStyle — the two namespaces
/// never overlap.
///
/// One source of truth per concern — panels never hand-pick spacing
/// numbers again. Values are in points; every panel renders at the same
/// width so the metrics transfer exactly.
enum PanelDesign {
    // MARK: panel chrome

    static let panelWidth: CGFloat = 520
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

    // MARK: row content geometry
    //
    // icon pinned to rowContentLeading; text starts after rowIconToText;
    // text trailing never passes rowContentTrailing. Inside the capsule
    // (inset rowCapsuleInsetX) the content is padded symmetrically:
    //   (rowContentLeading - rowCapsuleInsetX) == rowIconToText
    //   == (rowContentTrailing - rowCapsuleInsetX)
    // → 8pt everywhere; the 36pt single-line row gives the 20pt icon the
    // same 8pt above and below, so a cell's padding is uniform.

    static let rowContentLeading: CGFloat = 14
    static let rowContentTrailing: CGFloat = 14
    static let rowIconSize: CGFloat = 20
    static let rowIconToText: CGFloat = 8
}
