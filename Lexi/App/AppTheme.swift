import AppKit
import Foundation

extension SelectionToolbarApp {
    /// The card's input-area button group: AI features only (the copy/
    /// search/read/note/handoff tools are toolbar-only). Also rebuilds the
    /// toolbar buttons and card tabs from one config snapshot, refreshed at
    /// launch and on every settings change.
    func refreshCardActions() {
        var actionItems: [CardActionsPayload.Item] = []
        for feature in LexiStore.features() where feature.enabled && !feature.id.isEmpty {
            actionItems.append(.init(
                id: feature.id, name: feature.name.isEmpty ? "AI" : feature.name,
                icon: feature.icon.isEmpty ? "wand" : feature.icon))
        }

        // Toolbar scope: enabled tools + features, ordered by the shared
        // toolbarOrder list (ids may interleave; unknown/missing ids land
        // at the end in registry order).
        var available: [String: ToolbarAction] = [:]
        for tool in LexiStore.toolbarTools() where tool.enabled && !tool.id.isEmpty {
            available[tool.id] = ToolbarAction(
                id: tool.id, title: tool.displayName,
                icon: tool.icon.isEmpty ? "wand" : tool.icon)
        }
        for feature in LexiStore.features() where feature.enabled && !feature.id.isEmpty {
            available[feature.id] = ToolbarAction(
                id: feature.id, title: feature.name, icon: feature.icon)
        }
        // Seed the order list once: built-ins first, then features — the
        // pre-config bar order.
        if LexiStore.toolbarOrder().isEmpty {
            let seeded = LexiStore.toolbarTools().sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
                + LexiStore.features().sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
            LexiStore.saveToolbarOrder(seeded)
        }
        var barActions: [ToolbarAction] = []
        for id in LexiStore.toolbarOrder() {
            if let action = available.removeValue(forKey: id) {
                barActions.append(action)
            }
        }
        // The toolbar scope is the selection bar's OWN buttons — apply it
        // (this built the list and dropped it, which is why the settings
        // pane's toggles never reached the live toolbar).
        applyActions(barActions)
        // Panel tabs: fixed built-ins (Actions, Review).
        let ordered = [
            CardActionsPayload.PanelDef(id: "translate", name: "Actions", icon: "file-text"),
            CardActionsPayload.PanelDef(id: "review", name: "Review", icon: "book-open")
        ]

        FileLog.write("CARD actions refreshed tools+features=\(actionItems.count) panels=\(ordered.count)")
        handleCardActions(CardActionsPayload(
            actions: actionItems,
            panels: ordered
        ))
    }

    func restateCardChromeTints() {
        resultCloseButton?.contentTintColor = cardPinned ? cardTheme.foreground : cardTheme.secondaryText
        resultTrashButton?.contentTintColor = cardTheme.secondaryText
        resultCopyButton?.contentTintColor = cardTheme.secondaryText
        resultSaveButton?.contentTintColor = cardTheme.background
        resultIdleIcon?.contentTintColor = cardTheme.foreground
        resultLoadingLabel?.textColor = cardTheme.tertiaryText
        reviewAnswerLabel?.textColor = cardTheme.secondaryText
        reviewEmptyLabel?.textColor = cardTheme.tertiaryText
    }

    func applyCardTheme() {
        restateCardChromeTints()
        let controlStroke = PanelStyle.controlBorder(dark: theme == .dark)
        let appearance = theme == .dark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)

        resultPanel?.appearance = appearance
        if !isInputFocused {
            inputContainer?.layer?.borderColor = controlStroke.cgColor
        }
        if resultPanel != nil {
            rebuildRunTabs()
            renderActiveRun()
            layoutResultCard()
        }
    }


    func setInputFocused(_ focused: Bool) {
        isInputFocused = focused
        styleCardInputs(focused: focused ? .actions : .none)
    }

    /// Both card inputs (Actions bar + Notes search) share ONE surface
    /// definition: same fill, hairline, radius, placeholder tint. Focus
    /// (per field) deepens the border.
    enum CardInputFocus { case none, actions, search }

    func styleCardInputs(focused: CardInputFocus = .none) {
        let surface = cardTheme.inputFill.cgColor
        let hairline = cardTheme.hairline.cgColor
        let focusTint = cardTheme.foreground.withAlphaComponent(0.45).cgColor
        let border: (CardInputFocus) -> CGColor = { focus in
            focus == .none ? hairline : focusTint
        }
        for (container, focus) in [(inputContainer, CardInputFocus.actions), (noteSearchContainer, CardInputFocus.search)] {
            container?.layer?.backgroundColor = surface
            container?.layer?.borderColor = border(focus == .none || focus == focused ? focused : .none)
            container?.layer?.cornerRadius = 8
            container?.layer?.borderWidth = 1
        }
        // macOS 26+: the actions input is a glass capsule — layer fills and
        // hairlines don't draw on server-composited glass; theme and focus
        // ride the tint instead (focus lifts toward the foreground color).
        if #available(macOS 26.0, *) {
            cardInputGlass?.tintColor = focused == .actions
                ? cardTheme.foreground.withAlphaComponent(0.32)
                : PanelStyle.glassTint(dark: theme == .dark)
        }
        inputTextView?.placeholder = NSAttributedString(
            string: "Enter text",
            attributes: [.foregroundColor: cardTheme.tertiaryText, .font: NSFont.systemFont(ofSize: 13)]
        )
    }

    func showSettingsWindow(tab: SettingsTab = .general) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let controller: LexiSettingsWindowController
                if let existing = self.settingsWindowController {
                    controller = existing
                } else {
                    controller = LexiSettingsWindowController()
                    self.settingsWindowController = controller
                }
                controller.onPanelStyleChange = { [weak self] theme, opacity, blur in
                    PanelStyle.update(
                        opacity: opacity.map { CGFloat($0) / 100.0 },
                        blur: blur.flatMap(PanelStyle.Blur.init(rawValue:))
                    )
                    // Opacity/blur changes must repaint the live scrims too —
                    // PanelStyle.update only retunes materials. Reapplying the
                    // current theme re-derives every scrim from the new values.
                    self?.applyTheme(theme ?? (self?.theme ?? .dark).rawValue)
                    // The settings window itself follows the app theme so the
                    // Appearance controls have a visible effect in place.
                    controller.applyWindowAppearance(dark: (self?.theme ?? .dark) == .dark)
                }
                controller.onNativeSettingsReload = { [weak self] in
                    self?.shortcutMonitor?.reload()
                    self?.selectionPipeline?.reload()
                    self?.rebuildStatusMenu()
                    self?.refreshCardActions()
                }
                // The app menu (Settings… ⌘, / Quit) goes up WITH the first
                // Lexi window, not at launch: installing it during startup
                // raised inside applicationDidFinishLaunching and AppKit
                // swallowed the exception, silently killing everything
                // after it (shortcuts, clipboard store, debug server).
                self.installAppMainMenu()
                controller.show(tab: tab)
                // Match the window chrome to the persisted theme immediately —
                // onPanelStyleChange only fires on the next change.
                controller.applyWindowAppearance(dark: self.theme == .dark)
            }
        }
    }

}
