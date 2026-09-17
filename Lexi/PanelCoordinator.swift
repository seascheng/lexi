import Foundation

// ---------------------------------------------------------------------------
// PanelCoordinator — an audit trail, NOT a gate.
//
// Each panel manages its own lifecycle independently. macOS's native
// NSPanel focus handling (nonactivatingPanel + windowDidResignKey)
// handles cross-panel dismissal: clicking one panel dismisses transient
// overlays naturally; a pinned card stays. This type exists solely to
// log which surface the user last interacted with, for debugging.
// ---------------------------------------------------------------------------

final class PanelCoordinator {
    enum Surface: String {
        case toolbar, card, launcher, clipboard, settings
    }

    private(set) var active: Surface?

    func present(_ surface: Surface) {
        guard surface != active else { return }
        FileLog.write("PANEL present=\(surface.rawValue) was=\(active?.rawValue ?? "none")")
        active = surface
    }

    func dismissed(_ surface: Surface) {
        guard active == surface else { return }
        FileLog.write("PANEL dismissed=\(surface.rawValue)")
        active = nil
    }
}
