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
    static let searchHeight: CGFloat = 38

    // MARK: pills (filters/tabs) vs chips (inline content)

    static let pillHeight: CGFloat = 28
    /// Filter/tab pills read as capsules at their full height.
    static let pillCornerRadius: CGFloat = 14
    /// Inline content chips (folder grid) stay squarer.
    static let chipCornerRadius: CGFloat = 7

    // MARK: row selection capsule

    static let rowCapsuleInsetX: CGFloat = 6
    static let rowCapsuleInsetY: CGFloat = 3

    // MARK: row content geometry
    //
    // icon pinned to rowContentLeading; text starts after rowIconToText;
    // text trailing never passes rowContentTrailing. Inside the capsule
    // (inset rowCapsuleInsetX) the content is padded symmetrically:
    //   (rowContentLeading - rowCapsuleInsetX) == rowIconToText
    //   == (rowContentTrailing - rowCapsuleInsetX)
    // → 10pt everywhere; a 44pt single-line row gives the 24pt icon the
    // same 10pt above and below, so a cell's padding is uniform.
    // Type scale (TinyCast Theme parity): row primary 15, secondary 13,
    // search field 16, footer 12.

    static let rowContentLeading: CGFloat = 16
    static let rowContentTrailing: CGFloat = 16
    static let rowIconSize: CGFloat = 24
    static let rowIconToText: CGFloat = 10
}
