import AppKit

// ---------------------------------------------------------------------------
// The selection toolbar panel: build, place, show/hide, theme, action buttons.
// ---------------------------------------------------------------------------

extension SelectionToolbarApp {
    func applyTheme(_ themeName: String) {
        theme = ToolbarTheme(rawValue: themeName) ?? .dark
        let scrim = PanelStyle.scrim(dark: theme == .dark).cgColor
        container.layer?.backgroundColor = scrim
        dragHandle.theme = theme
        buttons.forEach { $0.theme = theme }
        // The result card follows the same theme: appearance, hairlines, and
        // every themed subview rebuilt (tinted icons, chips, markdown).
        if resultPanel != nil {
            let cardAppearance = theme == .dark
                ? NSAppearance(named: .vibrantDark)
                : NSAppearance(named: .vibrantLight)
            resultPanel.appearance = cardAppearance
            resultContainer.layer?.backgroundColor = scrim
            // chips: force a rebuild (the diff skips identical id/status/active)
            runChipViews.forEach { $0.removeFromSuperview() }
            runChipViews.removeAll()
            rebuildRunTabs()
            rebuildInputButtons()
            applyCardTheme()
            renderActiveRun()
            layoutResultCard()
        }
        launcherController.applyTheme(dark: theme == .dark)
        clipboardController.applyTheme(dark: theme == .dark)
        log("theme applied \(theme.rawValue)")
    }

    func currentMouseLocation(fallback: ShowPayload) -> NSPoint {
        // The payload carries the live cursor location in the same Cocoa coordinate
        // space NSScreen uses. Prefer it: NSEvent.mouseLocation freezes on the
        // display where the panel last lived when the selection happens in
        // another app on another display.
        if fallback.x != 0 || fallback.y != 0 {
            let payload = NSPoint(x: CGFloat(fallback.x), y: CGFloat(fallback.y))
            if NSScreen.screens.contains(where: { $0.frame.contains(payload) }) {
                return payload
            }
        }
        return NSEvent.mouseLocation
    }

    func clampedPanelOrigin(near point: NSPoint, width: CGFloat, payload: ShowPayload) -> NSPoint {
        // Direction-aware placement (openclip PopupPositioner): a top-to-bottom
        // drag (release more than 10pt below the press) leaves the selected
        // text ABOVE the cursor — place the bar BELOW it so the selection stays
        // visible. Every other gesture keeps the bar above the cursor.
        let belowCursor = (payload.downY ?? payload.y) < payload.y - 10
        var origin = NSPoint(
            x: point.x,
            y: belowCursor
                ? point.y - toolbarHeight - toolbarVerticalGap
                : point.y + toolbarVerticalGap
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 6), frame.maxX - width - 6)
            origin.y = min(max(origin.y, frame.minY + 6), frame.maxY - toolbarHeight - 6)
        }
        return origin
    }

    func hidePanel(force: Bool = false) {
        selectedText = ""
        panel.orderOut(nil)
    }

    func showPanel(_ payload: ShowPayload) {
        // Dual-track dedup: during selection migration both the helper's
        // tap and Rust's fire for the same selection — show once.
        guard selectionShowGate(payload.text) else { return }
        sourceApp = NSWorkspace.shared.frontmostApplication
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = currentMouseLocation(fallback: payload)
        let width = toolbarWidth(for: payload.actions?.count ?? actions.count)
        let origin = clampedPanelOrigin(near: point, width: width, payload: payload)
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: toolbarHeight)
        if let next = payload.actions {
            applyActions(next)
        }
        log("show panel textLength=\(text.count) mouse=\(Int(point.x)),\(Int(point.y)) payload=\(payload.x),\(payload.y) frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
        selectedText = text
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Opens (or focuses) the native settings window. Style changes flow
    /// both ways: applied in-process here, and mirrored into the Rust
    /// caches so a helper restart preserves them.
    func applyActions(_ nextActions: [ToolbarAction]) {
        let normalized = nextActions.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        actions = normalized
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        if actions.isEmpty {
            hidePanel(force: true)
            return
        }

        let width = toolbarWidth(for: actions.count)
        container.frame = NSRect(x: 0, y: 0, width: width, height: toolbarHeight)
        panel.setContentSize(NSSize(width: width, height: toolbarHeight))
        dragHandle.frame = NSRect(x: 0, y: 0, width: toolbarHandleWidth, height: toolbarHeight)

        for (index, action) in actions.enumerated() {
            addToolbarButton(action: action, index: index)
        }
    }

    func addToolbarButton(action: ToolbarAction, index: Int) {
        let button = ToolbarButton(
            frame: NSRect(
                x: toolbarHandleWidth + CGFloat(index) * toolbarSegmentWidth,
                // Inset capsule: 3pt of bar breathing room above and below the
                // highlight, so hover/press never touches the bar's edges.
                y: 3,
                width: toolbarSegmentWidth,
                height: toolbarHeight - 6
            )
        )
        button.autoresizingMask = []
        button.identifier = NSUserInterfaceItemIdentifier(action.id)
        button.toolTip = action.title
        button.image = lucideImage(for: action.icon, title: action.title)
        button.imageScaling = .scaleProportionallyDown
        button.theme = theme
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(runToolbarAction(_:))
        buttons.append(button)
        container.addSubview(button)
    }


    /// All card chrome tints in ONE place — build AND theme switches run it,
    /// so dark/light flips can never leave stale system colors behind.
    func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toolbarWidth(for: actions.count), height: toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let (background, content, _) = makePanelBackground(
            frame: panel.contentView?.bounds ?? .zero,
            surface: .bar
        )
        panel.contentView = background
        container = content
        dragHandle = ToolbarDragHandle(frame: NSRect(x: 0, y: 0, width: toolbarHandleWidth, height: toolbarHeight))
        dragHandle.autoresizingMask = [.height]
        dragHandle.theme = theme
        dragHandle.onMouseDown = { [weak self] event in
            self?.panel.performDrag(with: event)
        }
        container.addSubview(dragHandle)
        applyActions(actions)
    }

    /// Cutover probe: can THIS process host the global event tap? TCC grants
    /// accessibility per bundle — the answer decides whether the keyboard +
    /// selection pipeline can migrate from Rust now or must wait for the
    /// permission re-grant at app cutover. Log-only; nothing is installed.
    func probeEventTapAccess() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 1) ?? .cghidEventTap, // kCGSessionEventTap
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, _, _ in nil },
            userInfo: nil
        )
        if let tap {
            log("EVENTTAP probe: ok — helper may host the global tap")
            CFMachPortInvalidate(tap)
        } else {
            log("EVENTTAP probe: DENIED — helper lacks accessibility trust")
        }
    }

    // MARK: - Status item

}
