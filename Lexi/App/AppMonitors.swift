import AppKit
import Foundation

extension SelectionToolbarApp {
    func installMouseMonitors() {
        let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: downMask) { [weak self] event in
            self?.hideIfClickOutsidePanel(event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: downMask) { [weak self] event in
            self?.hideIfClickOutsidePanel(event)
        }

        // The cursor leaving the neighborhood dismisses the bar — the user
        // moved on without clicking (distance scales with screen width,
        // 180–280pt, openclip PopupMetrics.dismissalDistance).
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.hideIfCursorFarAway()
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.hideIfCursorFarAway()
            return event
        }

        // Scrolling means the user is reading past the selection.
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            self?.hidePanel()
        }

        // Any keystroke dismisses the bar — typing means the user moved on
        // (openclip's actions-mode rule). Escape additionally closes the
        // result card. Global key monitoring needs the helper's own
        // Accessibility grant; without it this silently never fires and the
        // other dismissal paths still work.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Selection gestures (⌘A/⌘L, ⇧+extend keys) are triggers, not
            // "moved on" typing: hiding here would kill the bar between
            // two extend presses, and the 600 ms dedup gate would then
            // block the re-show — extend-by-extend selection would end
            // with no bar at all.
            if SelectionPipeline.isSelectionKeyGesture(
                keyCode: event.keyCode, flags: event.modifierFlags) {
                return
            }
            self?.hidePanel()
            if event.keyCode == 53 { // kVK_Escape
                self?.escapeResultCardIfNeeded()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53, let self { // kVK_Escape
                self.escapeResultCardIfNeeded()
            }
            if event.keyCode == 48, let self, self.resultPanel != nil {
                // Tab goes to whoever owns the keyboard — panels are
                // independent surfaces (a pinned card stays visible while
                // the clipboard panel is key and must not steal its Tab).
                if self.resultPanel.isKeyWindow {
                    self.cyclePanelTab()
                    return nil
                }
                if self.clipboardController.isKeyWindow {
                    self.clipboardController.cycleChipTabs()
                    return nil
                }
            }
            return event
        }

        // A space switch leaves the bar floating over the wrong desktop.
        // Registered ONCE (app-lifetime, like the monitors above) — never
        // inside a monitor closure.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    func hideIfCursorFarAway() {
        guard panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - panel.frame.midX
        let dy = location.y - panel.frame.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        let radius = max(panel.frame.width, panel.frame.height) / 2
        if distance > cachedDismissalRadius + radius {
            hidePanel()
        }
    }


    func hideIfClickOutsidePanel(_ event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation

        // Result card: pinned cards stay until unpinned (pin button again).
        // Unpinned: hide; the runs stay in memory for the tabs bar.
        if resultPanel.isVisible,
           !cardPinned,
           event.window !== resultPanel,
           !resultPanel.frame.contains(screenPoint) {
            resultPanel.orderOut(nil)
                clearAllRuns()
        }

        guard panel.isVisible else {
            return
        }

        if event.window === panel {
            return
        }

        if panel.frame.contains(screenPoint) {
            return
        }

        log("hide outside click x=\(Int(screenPoint.x)) y=\(Int(screenPoint.y))")
        hidePanel()
    }
}
