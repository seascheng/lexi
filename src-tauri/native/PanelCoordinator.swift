import Foundation

// ---------------------------------------------------------------------------
// PanelCoordinator — the single owner of panel presentation.
//
// Every surface transition routes through present(_:): one place decides
// which other panels retire, so "operating one panel pops another" cannot
// happen by accident anymore. Hides run BEFORE the new surface shows —
// nothing of ours can steal focus during its own dismissal window.
//
// Policy: the toolbar/launcher/clipboard are transient overlays and never
// coexist with each other. The result card is a workspace: it also retires
// the overlays when IT opens (its actions replace them), and dies only on
// paste-through or explicit close. The settings window retires overlays
// but keeps the card.
// ---------------------------------------------------------------------------

final class PanelCoordinator {
    enum Surface: String {
        case toolbar, card, launcher, clipboard, settings
    }

    /// The surface the user is currently operating. `nil` = none of ours.
    private(set) var active: Surface?

    // Injected hide actions — keeps the coordinator uncoupled from the
    // controllers' internals.
    var hideToolbar: () -> Void = {}
    var hideLauncher: () -> Void = {}
    var hideClipboard: () -> Void = {}
    var hideCard: () -> Void = {}

    func present(_ surface: Surface) {
        guard surface != active else { return }
        FileLog.write("PANEL present=\(surface.rawValue) was=\(active?.rawValue ?? "none")")

        switch surface {
        case .toolbar:
            hideLauncher()
            hideClipboard()
        case .launcher:
            hideToolbar()
            hideClipboard()
        case .clipboard:
            hideToolbar()
            hideLauncher()
        case .card:
            hideToolbar()
            hideLauncher()
            hideClipboard()
        case .settings:
            hideToolbar()
            hideLauncher()
            hideClipboard()
        }
        active = surface
    }

    /// A surface went away on its own (outside click, Esc, dismissal) —
    /// keep the bookkeeping truthful.
    func dismissed(_ surface: Surface) {
        guard active == surface else { return }
        FileLog.write("PANEL dismissed=\(surface.rawValue)")
        active = nil
    }

    /// Paste-through and quit: every surface of ours goes away so nothing
    /// can surface-jump while another app takes focus.
    func dismissAll() {
        FileLog.write("PANEL dismissAll was=\(active?.rawValue ?? "none")")
        hideToolbar()
        hideLauncher()
        hideClipboard()
        hideCard()
        active = nil
    }
}
