import AppKit

// ---------------------------------------------------------------------------
// Result card: the streaming AI answer surface — multi-run tabs, markdown
// body, input bar, notes tab, review tab, pin, tag dropdown. An extension of
// SelectionToolbarApp; stored state stays in the class body in
// SelectionToolbarHelper.swift.
// ---------------------------------------------------------------------------

extension SelectionToolbarApp {
    // MARK: - Native result card (WebView parity): AiForm input bar,
    // multi-run tabs, loading/streaming/ready/error states, EntryTypeTags,
    // Copy/Save — rendered in AppKit and streamed in-process. The card is never
    // key unless clicked into (typing intent), and drags by its background.

    func buildResultCard() {
        resultPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: resultCardWidth, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        resultPanel.isOpaque = false
        resultPanel.backgroundColor = .clear
        resultPanel.hasShadow = true
        resultPanel.level = .popUpMenu
        resultPanel.hidesOnDeactivate = false
        resultPanel.isMovableByWindowBackground = true
        resultPanel.acceptsMouseMovedEvents = true
        resultPanel.delegate = self
        resultPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let (resultBackground, resultContent, isGlass) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 240),
            surface: .card
        )
        resultContainer = resultContent
        if isGlass {
            // Glass draws its own rounded shape — no clip wrapper needed.
            resultPanel.contentView = resultBackground
        } else {
            // Legacy: the vibrancy material draws past manual corner radii —
            // wrap and mask so only the rounded card shows (grey-rounded +
            // white-squared double edge fix).
            let clip = NSView(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 240))
            clip.wantsLayer = true
            clip.layer?.cornerRadius = 12
            clip.layer?.masksToBounds = true
            resultPanel.contentView = clip
            clip.addSubview(resultBackground)
        }

        // Panel tab strip (top): panel switcher (Actions/Notes/Review, the
        // Panel Config list) + close. WebView FloatingFrame parity.
        resultTabsView = NSView(frame: NSRect(x: 0, y: 210, width: resultCardWidth, height: 32))
        resultContainer.addSubview(resultTabsView)

        cardPanelTabsView = NSView(frame: NSRect(x: 12, y: 4, width: resultCardWidth - 24 - 28, height: 28))
        resultTabsView.addSubview(cardPanelTabsView)

        panelTabsControl = NSSegmentedControl()
        panelTabsControl.isHidden = true // replaced by the goty tab pills
        cardPanelTabsView.addSubview(panelTabsControl)
        buildPanelTabPills()

        // Pin toggle (WebView FloatingFrame parity): unpinned = dismisses on
        // outside click / Esc; pinned = stays. Replaces the close button —
        // closing happens by unpinning, then clicking away.
        resultCloseButton = NSButton(title: "", target: self, action: #selector(pinToggled))
        resultCloseButton.bezelStyle = .regularSquare
        resultCloseButton.isBordered = false
        resultCloseButton.image = lucideImage(for: "pin-off", title: "Pin")
        resultCloseButton.imageScaling = .scaleProportionallyDown
        resultCloseButton.contentTintColor = cardTheme.secondaryText
        resultCloseButton.toolTip = "Pin"
        resultCloseButton.frame = NSRect(x: resultCardWidth - 30, y: 7, width: 20, height: 20)
        resultTabsView.addSubview(resultCloseButton)
        resultRunsBar = NSView(frame: NSRect(x: 0, y: 180, width: resultCardWidth, height: 28))
        resultContainer.addSubview(resultRunsBar)

        resultTabsClip = HorizontalOnlyClip(frame: NSRect(x: 8, y: 0, width: resultCardWidth - 84, height: 28))
        resultTabsClip.drawsBackground = false
        resultTabsClip.hasVerticalScroller = false
        resultTabsClip.hasHorizontalScroller = false
        resultTabsClip.autohidesScrollers = true
        let runsDoc = NSView(frame: NSRect(x: 0, y: 0, width: resultCardWidth - 84, height: 28))
        resultTabsClip.documentView = runsDoc
        resultTabsClip.verticalForward = resultScrollView
        resultRunsBar.addSubview(resultTabsClip)

        runsSeparator = NSView(frame: .zero)
        runsSeparator.isHidden = true
        resultContainer.addSubview(runsSeparator)

        resultTrashButton = NSButton(title: "", target: self, action: #selector(clearRunsClicked))
        resultTrashButton.bezelStyle = .regularSquare
        resultTrashButton.isBordered = false
        resultTrashButton.image = lucideImage(for: "x", title: "Close all results")
        resultTrashButton.imageScaling = .scaleProportionallyDown
        resultTrashButton.toolTip = "Close all results"
        resultTrashButton.contentTintColor = cardTheme.secondaryText
        resultTrashButton.frame = NSRect(x: resultCardWidth - 34, y: 7, width: 20, height: 20)
        resultContainer.addSubview(resultTrashButton) // top level: can never be overdrawn

        // Content: markdown text + loading spinner + idle hint.
        resultScrollView = NSScrollView(frame: NSRect(x: 0, y: 70, width: resultCardWidth, height: 130))
        resultScrollView.drawsBackground = false
        resultScrollView.hasVerticalScroller = true
        resultScrollView.autohidesScrollers = true
        resultScrollView.scrollerStyle = .overlay
        resultContainer.addSubview(resultScrollView)

        resultTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 130))
        resultTextView.isEditable = false
        resultTextView.drawsBackground = false
        resultTextView.textContainerInset = NSSize(width: 14, height: 10)
        resultTextView.isVerticallyResizable = true
        resultTextView.autoresizingMask = [.width]
        resultTextView.textContainer?.lineFragmentPadding = 0
        resultScrollView.documentView = resultTextView

        // Layer spinner: NSProgressIndicator freezes on windows that are not
        // key; a CABasicAnimation rotation is driven by the render server and
        // always spins.
        resultLoadingIndicator = NSProgressIndicator(frame: NSRect(x: 14, y: 100, width: 16, height: 16))
        (resultLoadingIndicator as! NSProgressIndicator).controlSize = .small
        (resultLoadingIndicator as! NSProgressIndicator).style = .spinning
        resultContainer.addSubview(resultLoadingIndicator)

        resultLoadingLabel = NSTextField(labelWithString: "Running...")
        resultLoadingLabel.font = .systemFont(ofSize: 13)
        resultLoadingLabel.textColor = cardTheme.tertiaryText
        resultLoadingLabel.frame = NSRect(x: 36, y: 100, width: 200, height: 18)
        resultContainer.addSubview(resultLoadingLabel)

        // Translate tab's idle placeholder — a content-area view exactly like
        // cardNotesClip (notes) and reviewCardView (review): switching tabs
        // hides it wholesale, no per-control isHidden bookkeeping.
        translateIdleView = NSView(frame: NSRect(x: 0, y: 70, width: resultCardWidth, height: 130))
        translateIdleView.isHidden = true
        resultContainer.addSubview(translateIdleView)

        resultIdleIcon = NSImageView(frame: NSRect(x: resultCardWidth / 2 - 8, y: 32, width: 16, height: 16))
        resultIdleIcon.image = lucideImage(for: "sparkles", title: "Idle")
        resultIdleIcon.contentTintColor = cardTheme.foreground
        resultIdleIcon.imageScaling = .scaleProportionallyDown
        translateIdleView.addSubview(resultIdleIcon)

        resultIdleLabel = NSTextField(labelWithString: "Enter text, then choose an action.")
        resultIdleLabel.font = .systemFont(ofSize: 13)
        resultIdleLabel.textColor = cardTheme.secondaryText
        resultIdleLabel.alignment = .center
        resultIdleLabel.frame = NSRect(x: 10, y: 26, width: resultCardWidth - 20, height: 18)
        translateIdleView.addSubview(resultIdleLabel)

        resultIdleHint = NSTextField(labelWithString: "⏎ Run default")
        resultIdleHint.font = .systemFont(ofSize: 11)
        resultIdleHint.textColor = cardTheme.tertiaryText
        resultIdleHint.alignment = .center

        resultIdleHint.frame = NSRect(x: 10, y: 6, width: resultCardWidth - 20, height: 14)
        translateIdleView.addSubview(resultIdleHint)

        // Action bar: EntryTypeTags + Copy + Save (ready runs).
        resultActionBar = NSView(frame: NSRect(x: 10, y: 36, width: resultCardWidth - 20, height: 32))
        resultContainer.addSubview(resultActionBar)

        resultEntryBar = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 28))
        resultEntryBar.wantsLayer = true
        resultEntryBar.layer?.cornerRadius = 6
        resultEntryBar.layer?.borderWidth = 0.5
        resultActionBar.addSubview(resultEntryBar)
        for (index, title) in ["Word", "Phrase", "Pattern"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(entryTypeClicked(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.tag = index
            button.frame = NSRect(x: CGFloat(index) * 56 + 2, y: 2, width: 52, height: 22)
            resultEntryBar.addSubview(button)
            entryButtons.append(button)
        }

        resultCopyButton = NSButton(title: "", target: self, action: #selector(copyResultClicked))
        resultCopyButton.bezelStyle = .regularSquare
        resultCopyButton.isBordered = false
        resultCopyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy result")
        resultCopyButton.imageScaling = .scaleProportionallyDown
        resultCopyButton.contentTintColor = cardTheme.secondaryText
        resultCopyButton.toolTip = "Copy result"
        resultCopyButton.frame = NSRect(x: resultCardWidth - 190, y: 2, width: 26, height: 26)
        resultActionBar.addSubview(resultCopyButton)

        resultSaveButton = NSButton(title: "Save", target: self, action: #selector(saveResultClicked))
        resultSaveButton.bezelStyle = .regularSquare
        resultSaveButton.isBordered = false
        resultSaveButton.font = .systemFont(ofSize: 12, weight: .medium)
        resultSaveButton.wantsLayer = true
        resultSaveButton.layer?.cornerRadius = 6
        resultSaveButton.contentTintColor = cardTheme.background
        resultSaveButton.frame = NSRect(x: resultCardWidth - 158, y: 4, width: 148, height: 24)
        resultActionBar.addSubview(resultSaveButton)

        // Input bar (WebView AiForm parity): single-line keeps the action
        // buttons on the text row; multi-line moves them to a row below and
        // gives the text the full width.
        inputContainer = NSView(frame: NSRect(x: 10, y: 10, width: resultCardWidth - 20, height: 36))
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 8
        inputContainer.layer?.borderWidth = 1
        resultContainer.addSubview(inputContainer)

        inputTextView = CardInputTextView(frame: NSRect(x: 6, y: 4, width: resultCardWidth - 32 - 90, height: 26))
        inputTextView.font = .systemFont(ofSize: 13)
        inputTextView.drawsBackground = false
        inputTextView.isRichText = false
        inputTextView.isAutomaticQuoteSubstitutionEnabled = false
        inputTextView.isAutomaticDashSubstitutionEnabled = false
        inputTextView.delegate = self
        inputTextView.onBecameFocus = { [weak self] in
            self?.setInputFocused(true)
        }
        inputTextView.onLostFocus = { [weak self] in
            self?.setInputFocused(false)
        }
        inputTextView.textContainer?.lineFragmentPadding = 0
        inputTextView.placeholder = NSAttributedString(
            string: "Enter text",
            attributes: [.foregroundColor: cardTheme.tertiaryText, .font: NSFont.systemFont(ofSize: 13)]
        )
        inputContainer.addSubview(inputTextView)
        inputButtonsRow = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 28))
        inputButtonsClip = HorizontalOnlyClip(frame: NSRect(x: 0, y: 0, width: 90, height: 28))
        inputButtonsClip.drawsBackground = false
        inputButtonsClip.hasVerticalScroller = false
        inputButtonsClip.hasHorizontalScroller = false
        inputButtonsClip.autohidesScrollers = true
        inputButtonsClip.contentView.automaticallyAdjustsContentInsets = false
        inputButtonsClip.documentView = inputButtonsRow
        inputButtonsClip.verticalForward = resultScrollView
        inputContainer.addSubview(inputButtonsClip)

        // Notes tab: browsable note rows (click = copy).
        cardNotesClip = HorizontalOnlyClip(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 200))
        cardNotesClip.drawsBackground = false
        cardNotesClip.allowsVertical = true
        cardNotesClip.hasVerticalScroller = true
        cardNotesClip.autohidesScrollers = true
        cardNotesClip.scrollerStyle = .overlay
        notesTableView = NotesTable(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 200))
        notesTableView.onDoubleClickRow = { [weak self] row in
            guard let self, row >= 0, row < self.displayedNotes.count else { return }
            if let cell = self.notesTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteRowCell {
                cell.beginRenaming()
            }
        }
        notesTableView.onEnterKey = { [weak self] in
            guard let self, self.notesTableView.selectedRow >= 0 else { return }
            // Injects by note id: the visible list is filtered, so display
            // indexes must never cross into other tabs' snapshots.
            let row = self.notesTableView.selectedRow
            guard row >= 0, row < self.displayedNotes.count else { return }
            ClipboardPaster.pasteString(self.displayedNotes[row].content, previousApp: self.sourceApp)
        }
        notesTableView.rowHeight = 40
        notesTableView.intercellSpacing = .zero
        notesTableView.style = .fullWidth
        notesTableView.selectionHighlightStyle = .none
        notesTableView.backgroundColor = .clear
        notesTableView.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.resizingMask = .autoresizingMask
        notesTableView.addTableColumn(column)
        notesTableView.dataSource = self
        notesTableView.delegate = self
        notesTableView.target = self
        notesTableView.doubleAction = nil
        notesTableView.action = #selector(notesTableClicked(_:))
        notesTableView.sizeLastColumnToFit()
        NotificationCenter.default.addObserver(
            self, selector: #selector(notesClipScrolled),
            name: NSView.boundsDidChangeNotification, object: cardNotesClip.contentView
        )
        cardNotesClip.documentView = notesTableView
        resultContainer.addSubview(cardNotesClip)

        // Notes toolbar: live title search + tag filter chips. The search
        // surface IS the Actions input component: container + CardInputTextView
        // + overlay placeholder — identical construction, one language.
        noteSearchContainer = NSView(frame: .zero)
        noteSearchContainer.wantsLayer = true
        noteSearchContainer.layer?.cornerRadius = 8
        noteSearchContainer.layer?.borderWidth = 1
        resultContainer.addSubview(noteSearchContainer)

        noteSearchField = CardInputTextField(frame: .zero)
        let searchCell = VerticallyCenteredTextFieldCell()
        searchCell.stringValue = "" // bare NSTextFieldCell ships titled "Field"
        searchCell.isEditable = true
        searchCell.placeholderString = "Search notes"
        noteSearchField.cell = searchCell
        noteSearchField.font = .systemFont(ofSize: 13)
        noteSearchField.textColor = cardTheme.foreground
        noteSearchField.backgroundColor = .clear
        noteSearchField.drawsBackground = false
        noteSearchField.isBordered = false
        noteSearchField.focusRingType = .none
        noteSearchField.delegate = self
        noteSearchField.onBecameFocus = { [weak self] in
            self?.styleCardInputs(focused: .search)
        }
        noteSearchField.onLostFocus = { [weak self] in
            self?.styleCardInputs(focused: .none)
        }
        noteSearchContainer.addSubview(noteSearchField)

        noteTagBar = NSView(frame: .zero)
        resultContainer.addSubview(noteTagBar)

        // Review tab: word card + reveal + SM-2 grade buttons.
        reviewCardView = NSView(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 200))
        resultContainer.addSubview(reviewCardView)

        reviewWordLabel = NSTextField(labelWithString: "")
        reviewWordLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        reviewWordLabel.alignment = .center
        reviewWordLabel.frame = NSRect(x: 10, y: 120, width: resultCardWidth - 20, height: 28)
        reviewCardView.addSubview(reviewWordLabel)

        reviewAnswerLabel = NSTextField(labelWithString: "")
        reviewAnswerLabel.font = .systemFont(ofSize: 14)
        reviewAnswerLabel.textColor = cardTheme.secondaryText
        reviewAnswerLabel.alignment = .center
        reviewAnswerLabel.lineBreakMode = .byTruncatingTail
        reviewAnswerLabel.frame = NSRect(x: 20, y: 88, width: resultCardWidth - 40, height: 18)
        reviewCardView.addSubview(reviewAnswerLabel)

        reviewRevealButton = NSButton(title: "Reveal", target: self, action: #selector(revealReviewClicked))
        reviewRevealButton.bezelStyle = .rounded
        reviewRevealButton.controlSize = .regular
        reviewRevealButton.frame = NSRect(x: resultCardWidth / 2 - 40, y: 48, width: 80, height: 24)
        reviewCardView.addSubview(reviewRevealButton)

        for (index, title) in ["Again", "Hard", "Good", "Easy"].enumerated() {
            let grade = NSButton(title: title, target: self, action: #selector(gradeClicked(_:)))
            grade.bezelStyle = .rounded
            grade.controlSize = .small
            grade.tag = index
            grade.isEnabled = false
            grade.alphaValue = 0.4
            grade.frame = NSRect(x: 20 + CGFloat(index) * 98, y: 12, width: 88, height: 26)
            reviewCardView.addSubview(grade)
            reviewGradeButtons.append(grade)
        }

        let makeZone: (CardResizeZone.Edge, NSRect) -> CardResizeZone = { [weak self] edge, frame in
            let zone = CardResizeZone(edge: edge, frame: frame)
            zone.onResize = { [weak self] width, height in
                guard let self else { return }
                if let width { self.cardUserWidth = (min(max(width, 360), 760)).rounded() }
                if let height { self.cardUserHeight = (min(max(height, 240), 900)).rounded() }
                self.layoutResultCard()
            }
            zone.onReset = { [weak self] in
                self?.cardUserWidth = nil
                self?.cardUserHeight = nil
                self?.layoutResultCard()
            }
            return zone
        }
        resizeCorner = makeZone(.corner, NSRect(x: resultCardWidth - 16, y: 0, width: 16, height: 16))
        resizeRight = makeZone(.right, NSRect(x: resultCardWidth - 4, y: 16, width: 4, height: 180))
        resizeBottom = makeZone(.bottom, NSRect(x: 0, y: 0, width: resultCardWidth - 16, height: 4))
        resultContainer.addSubview(resizeCorner)
        resultContainer.addSubview(resizeRight)
        resultContainer.addSubview(resizeBottom)

        reviewEmptyLabel = NSTextField(labelWithString: "No words due for review.")
        reviewEmptyLabel.font = .systemFont(ofSize: 13)
        reviewEmptyLabel.textColor = cardTheme.tertiaryText
        reviewEmptyLabel.alignment = .center
        reviewEmptyLabel.frame = NSRect(x: 10, y: 90, width: resultCardWidth - 20, height: 18)
        reviewCardView.addSubview(reviewEmptyLabel)
    }

    private var activeRun: CardRun? {
        cardRuns.first { $0.id == activeRunId } ?? cardRuns.last
    }

    func showResultCard(_ payload: ResultShowPayload) {
        sourceApp = NSWorkspace.shared.frontmostApplication
        FileLog.write("CARD open=api runId=\(payload.runId ?? "-") feature=\(payload.featureId ?? "-") input=\(payload.inputText?.prefix(24) ?? "-")")
        panels.present(.card)
        // buttons, the input bar): the card presents and the AI stream
        // starts locally from the shared DB.
        var payload = payload
        var feature: LexiAIFeature?
        if let featureId = payload.featureId, !featureId.isEmpty {
            feature = LexiStore.aiFeature(id: featureId)
            if payload.title?.isEmpty != false, let row = feature {
                payload.title = row.name
                payload.icon = row.icon
            }
        }
        if let runId = payload.runId, !runId.isEmpty {
            let run = CardRun(
                id: runId,
                featureId: payload.featureId ?? "",
                title: payload.title?.isEmpty == false ? payload.title! : "AI",
                icon: payload.icon?.isEmpty == false ? payload.icon! : "wand"
            )
            cardRuns.append(run)
            activeRunId = runId
        } else {
            // Idle invocation: fresh session, no runs.
            cardRuns.removeAll()
            activeRunId = nil
        }
        // New runs always surface on the Actions panel.
        activePanel = "translate"
        if let input = payload.inputText, !input.isEmpty {
            inputTextView.string = input
            rebuildInputButtons()
        }
        log("card shown runs=\(cardRuns.count)")
        layoutResultCard()
        rebuildRunTabs()
        rebuildInputButtons()
        renderActiveRun()
        layoutResultCard()
        if !resultPanel.isVisible {
            placeResultCard()
            if !reduceMotion, let layer = resultPanel.contentView?.layer {
                resultPanel.alphaValue = 0
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = 6
                rise.toValue = 0
                rise.duration = 0.22
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(rise, forKey: "materialize")
                resultPanel.makeKeyAndOrderFront(nil)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    resultPanel.animator().alphaValue = 1
                })
            } else {
                resultPanel.alphaValue = 0
                resultPanel.makeKeyAndOrderFront(nil)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.15
                    resultPanel.animator().alphaValue = 1
                })
            }
        }
        applyCardTheme()
        // WebView parity: the selected text lands in the input bar,
        // editable for a follow-up run.
        // Every trigger path starts the run here — the helper owns the stream.
        if let runId = payload.runId, !runId.isEmpty, let feature {
            Task { [weak self] in
                await self?.streamRun(runId: runId, feature: feature, text: payload.inputText ?? "")
            }
        }
    }

    func handleCardActions(_ payload: CardActionsPayload) {
        cardActions = payload.actions
        panelDefs = (payload.panels ?? []).map { ($0.id, $0.name, $0.icon) }
        if !panelDefs.isEmpty {
            buildPanelTabPills()
        }
        if panelDefs.isEmpty {
            panelDefs = [("translate", "Actions", "file-text"), ("review", "Review", "book-open")]
        }
        rebuildInputButtons()
        layoutResultCard()
    }

    @objc private func panelTabClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showPanelTab(id)
    }

    func applyNoteFilters() {
        let query = noteSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        displayedNotes = cardNotesItems.filter { note in
            let title = (note.name.isEmpty ? note.content : note.name).lowercased()
            let matchesQuery = query.isEmpty || title.contains(query)
            let matchesCategory = noteActiveCategory == "all" || note.category == noteActiveCategory
            return matchesQuery && matchesCategory
        }
        notesTableView.reloadData()
        if !displayedNotes.isEmpty {
            notesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        layoutResultCard()
    }

    func rebuildNoteTagBar() {
        noteTagButtons.forEach { $0.removeFromSuperview() }
        noteTagButtons.removeAll()
        for name in ["all"] + cardCategories {
            let button = NSButton(title: name.capitalized, target: self, action: #selector(noteTagClicked(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.bezelStyle = .texturedRounded
            button.toolTip = name == "all" ? "All notes" : "Filter: \(name)"
            button.identifier = NSUserInterfaceItemIdentifier(name)
            noteTagBar.addSubview(button)
            noteTagButtons.append(button)
        }
        styleNoteTagButtons()
        layoutResultCard()
    }

    func layoutNoteTagButtons() {
        var x: CGFloat = 0
        for button in noteTagButtons {
            button.sizeToFit()
            let w = max(button.frame.width + 18, 40)
            button.frame = NSRect(x: x, y: 2, width: w, height: 20)
            x += w + 6
        }
    }

    func styleNoteTagButtons() {
        for button in noteTagButtons {
            let active = button.identifier?.rawValue == noteActiveCategory
            button.contentTintColor = active ? cardTheme.foreground : cardTheme.secondaryText
            button.layer?.backgroundColor = active
                ? cardTheme.selectedFill.cgColor
                : NSColor.clear.cgColor
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
        }
    }

    @objc private func noteTagClicked(_ sender: NSButton) {
        noteActiveCategory = sender.identifier?.rawValue ?? "all"
        styleNoteTagButtons()
        applyNoteFilters()
    }


    /// goty tab language: icon+label pills, active on the same-hue selected
    /// wash with full-radius caps, quiet otherwise.
    func buildPanelTabPills() {
        panelTabPills.forEach { $0.removeFromSuperview() }
        panelTabPills.removeAll()
        for def in panelDefs {
            let button = NSButton(title: "", target: self, action: #selector(panelTabClicked(_:)))
            button.isBordered = false
            button.toolTip = def.name
            button.identifier = NSUserInterfaceItemIdentifier(def.id)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.attributedTitle = tabPillTitle(def)
            cardPanelTabsView.addSubview(button)
            panelTabPills.append(button)
        }
        layoutPanelTabPills()
        stylePanelTabPills()
    }

    /// Icon + label as one attributed title: exact padding (8pt leading,
    /// 4pt gap) — NSButton's imageLeading spacing is untamable.
    func tabPillTitle(_ def: (id: String, name: String, icon: String), active: Bool = false) -> NSAttributedString {
        let title = NSMutableAttributedString(string: " ")
        if let icon = lucideImage(for: def.icon, title: def.name,
                                  color: active ? cardTheme.foreground : cardTheme.secondaryText) {
            icon.size = NSSize(width: 12, height: 12)
            let attachment = NSTextAttachment()
            attachment.image = icon
            // Center the glyph on the label's optical middle (cap height),
            // not on the baseline where attachments sit by default.
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            attachment.bounds = NSRect(
                x: 0, y: (font.capHeight - 12) / 2,
                width: 12, height: 12
            )
            title.append(NSAttributedString(attachment: attachment))
        }
        title.append(NSAttributedString(string: "  \(def.name)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: active ? cardTheme.foreground : cardTheme.secondaryText,
        ]))
        return title
    }

    func layoutPanelTabPills() {
        panelTabPills.forEach { $0.sizeToFit() }
        // ONE width for every pill — the tab strip reads as a set, not as
        // three differently-sized leftovers.
        let w = max(panelTabPills.map { $0.frame.width + 20 }.max() ?? 60, 60)
        let total = CGFloat(panelTabPills.count) * w + CGFloat(max(panelTabPills.count - 1, 0)) * 6
        var x = max((cardPanelTabsView.bounds.width - total) / 2, 0)
        for pill in panelTabPills {
            pill.frame = NSRect(x: x, y: 2, width: w, height: 26)
            x += w + 6
        }
    }

    func stylePanelTabPills() {
        for pill in panelTabPills {
            let def = panelDefs.first { $0.id == pill.identifier?.rawValue }
            let active = pill.identifier?.rawValue == activePanel
            // INVERTED active pill: foreground surface, background-colored
            // glyphs — contrast the quiet wash could never deliver.
            pill.attributedTitle = def.map { tabPillTitle($0, active: active) } ?? pill.attributedTitle
            // Template attachments tint through the button; the attributed
            // text carries its own color — both must agree.
            pill.contentTintColor = active ? cardTheme.foreground : cardTheme.secondaryText
            pill.layer?.backgroundColor = active
                ? cardTheme.selectedFill.cgColor
                : NSColor.clear.cgColor
        }
    }

    func cyclePanelTab() {
        let ids = panelDefs.map { $0.id }
        guard !ids.isEmpty, let current = ids.firstIndex(of: activePanel) else { return }
        showPanelTab(ids[(current + 1) % ids.count])
    }

    func showPanelTab(_ id: String, notify: Bool = true) {
        activePanel = id
        if !panelTabPills.isEmpty {
            stylePanelTabPills()
        }
        rebuildRunTabs()
        renderActiveRun()
        layoutResultCard()
        // Translate page = the input is the point: hand it first responder
        // (webview parity — the AiForm autofocused). Without this, a table
        // that was first responder on the Notes tab leaves the window with
        // no text target and every keystroke beeps.
        DispatchQueue.main.async {
            switch id {
            case "translate":
                self.inputTextView.window?.makeFirstResponder(self.inputTextView)
            case "notes":
                self.notesTableView.window?.makeFirstResponder(self.notesTableView)
            default:
                break
            }
        }
        guard notify else { return }
        if id == "notes" {
            reloadCardNotes()
        } else if id == "review" {
            loadReviewWord()
        }
    }

    /// Card review tab: fetch the next due word from the shared DB.
    func loadReviewWord() {
        if let next = LexiStore.nextReviewWord() {
            handleCardReview(CardReviewPayload(word: .init(
                id: next.id, word: next.word, translation: next.translation,
                pos: next.pos, entryType: next.entryType
            )))
        } else {
            handleCardReview(CardReviewPayload(word: nil))
        }
    }


    func handleCardNotes(_ payload: CardNotesPayload) {
        cardCategories = payload.categories ?? []
        cardNotesItems = payload.notes
        notesTableView.reloadData()
        notesTableView.sizeLastColumnToFit()
        if !cardNotesItems.isEmpty {
            notesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            notesTableView.scrollRowToVisible(0)
        }
        rebuildNoteTagBar()
        applyNoteFilters()
        layoutResultCard()
    }

    /// Mouse click on a row: select it (selectionDidChange copies the
    /// content) and arm the card for Enter. Injection happens on Enter only.
    @objc private func notesTableClicked(_ sender: NSTableView) {
        setInputFocused(false)
    }
    // picker is an in-card dropdown layer instead: same material, opens at
    // the pill, click-outside/Esc closes, picking posts note-tag.


    func showTagMenu(noteId: Int64, tag: String?, anchor: NSView) {
        guard noteId != 0,
              let host = resultPanel.contentView else { return }
        closeTagDropdown()

        let categories = cardCategories.isEmpty
            ? Array(Set(cardNotesItems.compactMap { $0.category })).sorted()
            : cardCategories
        let dropdown = TagDropdownView(
            tags: categories,
            current: tag,
            theme: cardTheme,
            onPick: { [weak self] name in
                self?.closeTagDropdown()
                self?.handleAction(action: "note-tag", text: "\(noteId)|\(name ?? "")")
            }
        )
        let pillRect = anchor.convert(anchor.bounds, to: host)
        var origin = NSPoint(x: min(pillRect.minX, host.bounds.width - dropdown.frame.width - 8), y: pillRect.minY - dropdown.frame.height - 4)
        if origin.y < 8 {
            origin.y = pillRect.maxY + 4
        }
        dropdown.frame.origin = origin
        host.addSubview(dropdown)
        tagDropdown = dropdown

        tagDropdownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closeTagDropdown()
                return nil
            }
            if event.type != .keyDown {
                let location = event.locationInWindow
                let inDropdown = self.tagDropdown.map {
                    $0.convert($0.bounds, to: nil).contains(location)
                } ?? false
                if !inDropdown {
                    self.closeTagDropdown()
                }
            }
            return event
        }
    }

    func closeTagDropdown() {
        tagDropdown?.removeFromSuperview()
        tagDropdown = nil
        if let tagDropdownMonitor {
            NSEvent.removeMonitor(tagDropdownMonitor)
            self.tagDropdownMonitor = nil
        }
    }

    func noteDeleteClickedId(_ id: Int64) {
        handleAction(action: "note-delete", text: String(id))
    }

    func noteRenamed(id: Int64, name: String) {
        let payload: [String: Any] = ["id": id, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return }
        handleAction(action: "note-rename", text: body)
    }

    func handleCardReview(_ payload: CardReviewPayload) {
        guard let word = payload.word else {
            reviewEmptyLabel.isHidden = false
            reviewWordLabel.stringValue = ""
            reviewAnswerLabel.stringValue = ""
            reviewRevealButton.isHidden = true
            reviewGradeButtons.forEach { $0.isEnabled = false; $0.alphaValue = 0.4 }
            reviewCurrentWordId = 0
            layoutResultCard()
            return
        }
        reviewEmptyLabel.isHidden = true
        reviewRevealButton.isHidden = false
        reviewCurrentWordId = word.id
        reviewWordLabel.stringValue = word.word
        reviewAnswerLabel.stringValue = ""
        reviewRevealButton.isEnabled = true
        reviewRevealButton.title = "Reveal"
        reviewGradeButtons.forEach { $0.isEnabled = false; $0.alphaValue = 0.4 }
        reviewAnswerLabel.toolTip = word.translation
        layoutResultCard()
    }

    @objc private func revealReviewClicked() {
        guard reviewCurrentWordId != 0 else { return }
        reviewAnswerLabel.stringValue = reviewAnswerLabel.toolTip ?? ""
        reviewRevealButton.isEnabled = false
        reviewGradeButtons.forEach { $0.isEnabled = true; $0.alphaValue = 1 }
    }

    @objc private func gradeClicked(_ sender: NSButton) {
        let ratings = ["again", "hard", "good", "easy"]
        guard reviewCurrentWordId != 0 else { return }
        reviewGradeButtons.forEach { $0.isEnabled = false; $0.alphaValue = 0.4 }
        LexiStore.applyReviewGrade(id: reviewCurrentWordId, rating: ratings[sender.tag])
        loadReviewWord()
    }

    func handleResultEvent(_ payload: ResultEventPayload) {
        let runId = payload.runId?.isEmpty == false ? payload.runId! : activeRunId
        guard let run = cardRuns.first(where: { $0.id == runId }) ?? activeRun else { return }

        if let error = payload.error {
            run.status = "error"
            run.text = error
        } else if payload.done {
            run.text = payload.chunk ?? run.text
            run.status = "ready"
            if let json = payload.translationJson {
                run.translationJson = json
                run.entryType = inferredEntryType(for: jsonStringField(json, "word") ?? run.title)
            }
            if payload.saved == true {
                run.saved = true
            }
        } else if let chunk = payload.chunk {
            run.text += chunk
            run.status = "streaming"
        }

        // Unconditional: the event mutated a run; re-render active state.
        renderActiveRun()
        layoutResultCard()
    }

    /// Accessory apps ship without a menu bar, which silently kills the
    /// standard text key equivalents (Cmd+C/V/X/A) in every text view. A
    /// minimal Edit submenu restores the system behavior — no per-key
    /// monitors, no custom handling.
    func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func spinnerStart() {
        resultLoadingIndicator.isHidden = false
        (resultLoadingIndicator as? NSProgressIndicator)?.startAnimation(nil)
    }

    func spinnerStop() {
        (resultLoadingIndicator as? NSProgressIndicator)?.stopAnimation(nil)
    }

    /// Re-render the active run's content area (loading / streaming / error /
    /// ready) and the action bar state.
    func renderActiveRun() {
        let run = activeRun
        let status = run?.status

        resultLoadingIndicator.isHidden = status != "loading"
        if status == "loading" {
            spinnerStart()
        } else {
            spinnerStop()
        }
        resultLoadingLabel.isHidden = status != "loading"
        translateIdleView.isHidden = activePanel != "translate" || run != nil
        resultScrollView.isHidden = !(status == "streaming" || status == "ready" || status == "error")
        resultActionBar.isHidden = status != "ready"

        if status == "streaming" || status == "ready" {
            let dark = theme == .dark
            resultTextView.textStorage?.setAttributedString(LightMarkdown.attributed(run?.text ?? "", dark: dark))
            // The text view is the scroll view's documentView: its frame must
            // track the content or everything past the initial height stays
            // clipped (window grows, text doesn't — exactly the reported bug).
            //
            // WIDTH is owned by the scroll view's autoresizing alone — setting
            // it manually here fought the autoresize (392 vs 420 every event,
            // text container flapping ±28pt = the streaming jitter where each
            // line's last glyphs wrapped and unwrapped). The inset already
            // narrows the text column; measurement below matches it.
            let needed = markdownRenderedHeight(run?.text ?? "", atWidth: resultScrollView.frame.width - 28)
            resultTextView.frame = NSRect(
                x: 0,
                y: 0,
                width: resultScrollView.frame.width,
                height: max(needed + resultTextView.textContainerInset.height * 2, resultScrollView.frame.height)
            )
            if status == "streaming" {
                resultTextView.scrollToEndOfDocument(nil)
            }
        } else if status == "error" {
            let error = NSMutableAttributedString()
            error.append(NSAttributedString(string: "⚠︎ Action failed\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
            ]))
            error.append(NSAttributedString(string: run?.text ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]))
            resultTextView.textStorage?.setAttributedString(error)
        }

        if status == "ready" {
            updateEntryTypeTags()
            updateSaveButton()
        }
        rebuildRunTabs()
// (diag removed)
    }

    @objc private func pinToggled() {
        cardPinned.toggle()
        resultCloseButton.image = lucideImage(for: cardPinned ? "pin" : "pin-off", title: cardPinned ? "Unpin" : "Pin")
        resultCloseButton.toolTip = cardPinned ? "Unpin" : "Pin"
        resultCloseButton.contentTintColor = cardPinned ? cardTheme.foreground : cardTheme.secondaryText
        log("card pinned=\(cardPinned)")
    }

    func clearAllRuns(quietly: Bool) {
        cardRuns.removeAll()
        activeRunId = nil
        cardPinned = false
        rebuildRunTabs()
    }

    @objc private func clearRunsClicked() {
        // Close all run tabs but keep the panel: it returns to the idle
        // input state ("Enter text, then choose an action.").
        cardRuns.removeAll()
        activeRunId = nil
        rebuildRunTabs()
        renderActiveRun()
        layoutResultCard()
    }

    /// Single unified layout pass: measures content, positions every strip,
    /// sizes the panel (top-anchored so growth pushes down, not up).
    func layoutResultCard() {
        let width = cardUserWidth ?? resultCardWidth
        let side: CGFloat = 10
        let contentWidth = width - side * 2

        // --- Input bar (AiForm parity) ---
        // Measure the text at ROW-layout width (full width minus the button
        // group) — the same value regardless of current layout, so switching
        // between single- and multi-line never oscillates.
        let buttonGroupWidth: CGFloat = cardActions.isEmpty
            ? 0
            : CGFloat(cardActions.count) * 30 + CGFloat(cardActions.count - 1) * 2 + 4
        let availForButtons = contentWidth - 50 - 10
        let clipW = min(buttonGroupWidth, availForButtons)
        let rowLayoutWidth = contentWidth - 8 - clipW
        // Two-stage measure (WebView parity): judge multi-line at the ROW
        // width, but size the text view at the FULL width it will actually
        // render at — otherwise the two widths disagree and text is clipped
        // or a tall empty frame is left behind.
        let rowMeasured = inputTextHeight(atWidth: rowLayoutWidth - 12)
        let isMultiline = rowMeasured > 18 // one 13pt line ≈ 17.5pt: anything more is a textarea
        let fullMeasured = inputTextHeight(atWidth: contentWidth - 24)
        let textHeight = isMultiline ? min(fullMeasured, 152) : max(min(rowMeasured, 34), 24)
        let inputBarHeight = isMultiline ? textHeight + 12 + 6 + 28 + 8 : textHeight + 8

        if isMultiline {
            inputTextView.textContainerInset = NSSize(width: 6, height: 6)
            inputTextView.frame = NSRect(x: 6, y: 6 + 28, width: contentWidth - 12, height: textHeight + 12)
            inputButtonsRow.frame = NSRect(x: 0, y: 0, width: buttonGroupWidth, height: 28)
            inputButtonsClip.frame = NSRect(x: 6, y: 5, width: min(buttonGroupWidth, contentWidth - 12), height: 26)
            inputButtonsClip.contentView.scroll(to: NSPoint(x: max(0, buttonGroupWidth - inputButtonsClip.frame.width), y: 0))
            inputButtonsClip.reflectScrolledClipView(inputButtonsClip.contentView)
        } else {
            // Fixed single-line row, vertically centered (WebView parity).
            inputTextView.textContainerInset = NSSize(width: 6, height: (max(textHeight, 24) - 17) / 2)
            inputTextView.frame = NSRect(x: 6, y: (inputBarHeight - max(textHeight, 24)) / 2, width: rowLayoutWidth, height: max(textHeight, 24))
            let buttonsHeight: CGFloat = 28
            inputButtonsRow.frame = NSRect(x: 0, y: 0, width: buttonGroupWidth, height: 28)
            inputButtonsClip.frame = NSRect(
                x: 6 + rowLayoutWidth + 4,
                y: (inputBarHeight - buttonsHeight) / 2,
                width: clipW,
                height: buttonsHeight
            )
            inputButtonsClip.contentView.scroll(to: NSPoint(x: max(0, buttonGroupWidth - clipW), y: 0))
            inputButtonsClip.reflectScrolledClipView(inputButtonsClip.contentView)
        }

        // --- Strip sizes (screen order top→bottom: tabs / input / runs /
        // content / actionBar). Notes & Review replace everything below tabs.
        let isTranslate = activePanel == "translate"
        let tabsH: CGFloat = 36
        let runsH: CGFloat = (isTranslate && !cardRuns.isEmpty) ? 28 : 0
        let inputH = isTranslate ? inputBarHeight : 0
        let status = activeRun?.status
        var contentH: CGFloat = 76 // idle
        if activePanel == "notes" {
            let listH = min(CGFloat(max(displayedNotes.count, 1)) * 40 + 12, 420)
            contentH = 28 + 8 + 24 + 6 + listH // search + gap + chips + gap + list
        } else if activePanel == "review" {
            contentH = 200
        } else if status == "loading" {
            contentH = 48
        } else if status == "streaming" || status == "ready" || status == "error" {
            contentH = min(max(markdownRenderedHeight(activeRun?.text ?? "", atWidth: width - 28) + 24, 64), 440)
        }

        let actionH: CGFloat = (isTranslate && status == "ready") ? 34 : 0

        // Total-height cap = min(640, on-screen room below the top anchor).
        // Overflow is absorbed by the content strip (internal scrolling), so
        // the window NEVER has to be re-anchored upward mid-stream — the
        // previous clamp-to-screen behavior made the card "jump upward" as
        // every streamed chunk grew the window past the screen bottom.
        var maxTotal: CGFloat = 640
        if resultPanel.isVisible,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(resultPanel.frame.origin) }) ?? NSScreen.main {
            maxTotal = min(maxTotal, max(240, resultPanel.frame.maxY - screen.visibleFrame.minY - 8))
        }
        let overflow = max(0, tabsH + 6 + inputH + 4 + runsH + contentH + actionH + side - maxTotal)
        var contentFinal = max(60, contentH - overflow)
        // --- Frames, AppKit y-up, derived strictly bottom-up so adjacent
        // strips can never overlap or drift: action → content → runs →
        // input → tabs. contentFinal absorbs clamping (min 60).
        let actionY: CGFloat = 10
        let contentY = actionY + actionH
        var runsY = contentY + contentFinal
        var inputY = runsY + runsH + 4
        var tabsY = inputY + inputH + 6
        var clampedTotal = tabsY + tabsH
        // User-resized height wins: the content strip absorbs the requested
        // total (overflow scrolls internally), auto sizing stays untouched.
        if let userH = cardUserHeight {
            let cappedH = min(userH, maxTotal)
            let fixed = clampedTotal - contentFinal
            let userH = cappedH
            contentFinal = max(60, userH - fixed)
            runsY = contentY + contentFinal
            inputY = runsY + runsH + 4
            tabsY = inputY + inputH + 6
            clampedTotal = tabsY + tabsH
        }

        resultTabsView.frame = NSRect(x: 0, y: tabsY, width: width, height: tabsH)
        cardPanelTabsView.frame = NSRect(x: 8, y: 2, width: width - 48, height: 28)

        inputContainer.isHidden = !isTranslate
        if isTranslate {
            inputContainer.frame = NSRect(x: side, y: inputY, width: contentWidth, height: inputBarHeight)
        }

        resultRunsBar.isHidden = runsH == 0
        let stripW = width - 48
        resultRunsBar.frame = NSRect(x: 12, y: runsY, width: width - 24, height: runsH)
        resultTabsClip.frame = NSRect(x: 0, y: 0, width: stripW, height: 28)
        resultTabsClip.documentView?.frame = NSRect(x: 0, y: 0, width: max(runTabsContentWidth, stripW), height: 28)

        resultScrollView.isHidden = !isTranslate || !(status == "streaming" || status == "ready" || status == "error")
        resultScrollView.frame = NSRect(x: 0, y: contentY, width: width, height: contentFinal)
        resultLoadingIndicator.isHidden = !isTranslate || status != "loading"
        resultLoadingLabel.isHidden = !isTranslate || status != "loading"
        resultLoadingIndicator.frame.origin = NSPoint(x: 14, y: contentY + contentFinal - 16 - 12)
        resultLoadingLabel.frame.origin = NSPoint(x: 36, y: contentY + contentFinal - 14 - 13)
        translateIdleView.isHidden = !isTranslate || activeRun != nil
        translateIdleView.frame = NSRect(x: 0, y: contentY, width: width, height: contentFinal)
        resultIdleLabel.frame = NSRect(x: 10, y: contentFinal / 2 - 6, width: width - 20, height: 18)
        resultIdleHint.frame = NSRect(x: 10, y: contentFinal / 2 - 26, width: width - 20, height: 14)
        resultIdleIcon.frame = NSRect(x: width / 2 - 8, y: contentFinal / 2 + 18, width: 16, height: 16)

        let notesUIVisible = activePanel == "notes"
        let searchH: CGFloat = 30
        let chipsH: CGFloat = 24
        noteSearchContainer.isHidden = !notesUIVisible
        noteTagBar.isHidden = !notesUIVisible
        cardNotesClip.isHidden = !notesUIVisible
        if notesUIVisible {
            let listTop = contentY + contentFinal
            noteSearchContainer.frame = NSRect(x: 12, y: listTop - searchH, width: width - 24, height: searchH)
            noteSearchField.frame = NSRect(x: 8, y: 3, width: width - 24 - 16, height: searchH - 6)
            noteTagBar.frame = NSRect(x: 12, y: listTop - searchH - 6 - chipsH, width: width - 24, height: chipsH)
            layoutNoteTagButtons()
            cardNotesClip.frame = NSRect(
                x: 0,
                y: contentY,
                width: width,
                height: max(contentFinal - searchH - 8 - chipsH - 6, 64)
            )
        }

        reviewCardView.isHidden = activePanel != "review"
        reviewCardView.frame = NSRect(x: 0, y: contentY, width: width, height: contentFinal)
        relayoutReview(width: width, height: contentFinal)

        resultActionBar.isHidden = actionH == 0
        resultActionBar.frame = NSRect(x: side, y: actionY, width: contentWidth, height: actionH)

        // Top-anchored resize driven by MODEL values (cardX/cardTopY), never
        // by the animating window frame: reading frame.maxY mid-animation made
        // each stream chunk re-anchor to an intermediate position and the
        // card's top edge jittered up and down while text streamed in.
        if resultPanel.isVisible {
            // Anchor directly on the LIVE frame: setFrame is atomic (no
            // animation), so the frame always reflects the user's last drag.
            // The cached cardX/cardTopY model was built for the removed
            // animation and caused snap-back after user drags.
            let live = resultPanel.frame
            var target = NSRect(x: live.minX, y: live.maxY - clampedTotal, width: width, height: clampedTotal)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: live.minX, y: live.maxY)) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                target.origin.y = max(target.origin.y, visible.minY + 8)
                target.origin.x = min(max(target.minX, visible.minX + 8), visible.maxX - target.width - 8)
            }
            animatePanelFrame(to: target)
        } else {
            animatePanelFrame(to: NSRect(x: 0, y: 0, width: width, height: clampedTotal))
        }
        resultContainer.frame = NSRect(x: 0, y: 0, width: width, height: clampedTotal)
        resizeCorner.frame = NSRect(x: width - 16, y: 0, width: 16, height: 16)
        resizeRight.frame = NSRect(x: width - 4, y: 16, width: 4, height: clampedTotal - 32)
        resizeBottom.frame = NSRect(x: 0, y: 0, width: width - 16, height: 4)
        resizeCorner.setDark(theme == .dark)
        // Right-anchored chrome must ride the window edge (build-time frames
        // pin to the default 420 width and go stale after a user resize).
        let segW = panelTabsControl.fittingSize.width
        panelTabsControl.frame = NSRect(
            x: max(0, (cardPanelTabsView.bounds.width - segW) / 2),
            y: 1,
            width: segW,
            height: 26
        )
        resultCloseButton.frame.origin.x = width - 32
        resultTrashButton.frame = NSRect(x: width - 30, y: runsY + 3, width: 22, height: 22)
        resultTrashButton.isHidden = runsH == 0
        runsSeparator.isHidden = runsH == 0
        runsSeparator.frame = .zero
        resultTrashButton.frame = NSRect(x: width - 30, y: runsY + 3, width: 22, height: 22)
        resultTrashButton.isHidden = runsH == 0
        resultRunsBar.isHidden = runsH == 0
        updateEntryTypeTags()
    }

    func markdownRenderedHeight(_ markdown: String, atWidth width: CGFloat) -> CGFloat {
        // Measured with a real NSLayoutManager: NSAttributedString.boundingRect
        // drifts on CJK line heights/paragraph spacing, which cut text off at
        // the bottom of the card.
        let storage = NSTextStorage(attributedString: LightMarkdown.attributed(markdown, dark: theme == .dark))
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    func inputTextHeight(atWidth width: CGFloat) -> CGFloat {
        // NSLayoutManager measurement — boundingRect drifts on CJK and on
        // the exact wrap count this height decision depends on.
        let storage = NSTextStorage(
            attributedString: NSAttributedString(
                string: inputTextView.string.isEmpty ? " " : inputTextView.string,
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            )
        )
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Review card: word block vertically centered in the content area,
    /// everything tracks the live width/height.
    func relayoutReview(width: CGFloat, height: CGFloat) {
        let mid = height / 2
        reviewWordLabel.font = .systemFont(ofSize: min(28, max(20, height / 7)), weight: .semibold)
        reviewWordLabel.frame = NSRect(x: 10, y: mid + 16, width: width - 20, height: 34)
        reviewAnswerLabel.frame = NSRect(x: 20, y: mid - 8, width: width - 40, height: 18)
        reviewRevealButton.frame = NSRect(x: width / 2 - 40, y: mid - 44, width: 80, height: 24)
        for (index, grade) in reviewGradeButtons.enumerated() {
            grade.frame = NSRect(x: 20 + CGFloat(index) * 98, y: 16, width: 88, height: 26)
        }
        reviewEmptyLabel.frame = NSRect(x: 10, y: mid - 9, width: width - 20, height: 18)
    }

    /// Height changes apply in ONE atomic setFrame: subview geometry is set
    /// to the new layout in the same pass, so animating the window frame left
    /// a torn intermediate (new subview positions inside the old window) and
    /// tab switches / state changes visibly jittered. The top-anchored target
    /// means an atomic frame change never moves the top edge.
    func animatePanelFrame(to target: NSRect) {
        resultPanel.setFrame(target, display: true)
    }

    func placeResultCard() {
        let cardSize = resultPanel.frame.size
        let origin: NSPoint
        if panel.isVisible {
            // Card unfolds from the toolbar: left-aligned with it, 8pt below
            // its bottom edge, growing DOWNWARD. Flips above only when the
            // screen has no room below the toolbar.
            let tb = panel.frame
            var p = NSPoint(x: tb.minX, y: tb.minY - cardSize.height - 8)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: tb.midX, y: tb.midY)) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                if p.y < visible.minY + 8 {
                    p.y = tb.maxY + 8
                }
                p.x = min(max(p.x, visible.minX + 8), visible.maxX - cardSize.width - 8)
            }
            origin = p
        } else {
            // Hapigo-style placement: the card's TOP-LEFT corner matches the
            // mouse; only an on-screen overflow nudges it back into the
            // visible frame.
            let point = NSEvent.mouseLocation
            var p = NSPoint(x: point.x, y: point.y - cardSize.height)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                let frame = screen.visibleFrame
                p.x = min(max(p.x, frame.minX + 8), frame.maxX - cardSize.width - 8)
                p.y = min(max(p.y, frame.minY + 8), frame.maxY - cardSize.height - 8)
            }
            origin = p
        }
        resultPanel.setFrameOrigin(origin)
    }
}

extension SelectionToolbarApp {
    func rebuildRunTabs() {
        let dark = theme == .dark
        let doc = resultTabsClip.documentView ?? NSView()
        if runChipViews.count == cardRuns.count {
            var unchanged = true
            for (chip, run) in zip(runChipViews, cardRuns) {
                let activeNow = run.id == activeRunId
                if chip.runId != run.id || chip.statusKey != run.status || chip.isActiveChip != activeNow {
                    unchanged = false
                    break
                }
            }
            if unchanged { return }
        }
        runChipViews.forEach { $0.removeFromSuperview() }
        runChipViews.removeAll()

        var x: CGFloat = 0
        for run in cardRuns {
            let chip = RunChipView(run: run, dark: dark)
            chip.onSelected = { [weak self] in
                self?.activeRunId = run.id
                self?.renderActiveRun()
                self?.layoutResultCard()
            }
            chip.onDismissed = { [weak self] in
                self?.dismissRun(run.id)
            }
            chip.setActive(run.id == activeRunId, dark: dark)
            doc.addSubview(chip)
            runChipViews.append(chip)
            chip.frame = NSRect(x: x, y: 3, width: chip.fitWidth, height: 24)
            x += chip.fitWidth + 4
        }
        // Horizontal scroll: document view grows with the chips; keep the
        // newest run visible. The strip caps at width-44; layoutResultCard
        // sizes it to the content when the chips fit.
        runTabsContentWidth = max(x - 4, 0)
        let visible = resultTabsClip.frame.width
        let contentW = max(x - 4, visible)
        doc.frame = NSRect(x: 0, y: 0, width: contentW, height: 28)
        resultTabsClip.contentView.scroll(to: NSPoint(x: contentW - visible, y: 0))
        resultTabsClip.reflectScrolledClipView(resultTabsClip.contentView)
    }

    func rebuildInputButtons() {
        inputButtonsRow.subviews.forEach { $0.removeFromSuperview() }
        let hasInput = !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for (index, item) in cardActions.enumerated() {
            let button = HoverIconButton(frame: .zero)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.target = self
            button.action = #selector(inputActionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(item.id)
            button.image = lucideImage(for: item.icon, title: item.name)
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .labelColor
            button.toolTip = "\(item.name) input text"
            button.isEnabled = hasInput
            button.alphaValue = hasInput ? 1 : 0.4
            button.frame = NSRect(x: CGFloat(index) * 30, y: 0, width: 28, height: 28)
            inputButtonsRow.addSubview(button)
        }
    }

    func updateEntryTypeTags() {
        let run = activeRun
        let hasEntry = run?.translationJson != nil
        resultEntryBar.isHidden = !hasEntry
        let types = ["word", "phrase", "pattern"]
        for (index, button) in entryButtons.enumerated() {
            let active = run?.entryType == types[index]
            let saved = run?.saved == true
            button.isEnabled = !saved && hasEntry
            button.alphaValue = saved ? 0.4 : 1
            button.layer?.backgroundColor = active
                ? cardTheme.selectedFill.cgColor
                : NSColor.clear.cgColor
        }
        if hasEntry {
            var width: CGFloat = 6
            for button in entryButtons {
                width += button.attributedTitle.size().width + 16
            }
            resultEntryBar.frame.size.width = max(width, 150)
            var x: CGFloat = 2
            for button in entryButtons {
                button.frame.origin.x = x
                x += button.attributedTitle.size().width + 16
            }
        }
    }

    func updateSaveButton() {
        let run = activeRun
        let canSave = run?.translationJson != nil
        resultSaveButton.isHidden = !canSave
        // Bar-local coordinates (the bar is inset by `side` from the card and
        // sized contentWidth): anchor to its right edge so Copy/Save ride the
        // card edge at any user width.
        let barW = resultActionBar.bounds.width
        resultSaveButton.frame.origin.x = barW - 148 - 10
        resultCopyButton.frame.origin.x = canSave ? barW - 148 - 10 - 26 - 8 : barW - 26 - 10
        if canSave {
            let saved = run?.saved == true
            resultSaveButton.isEnabled = !saved
            resultSaveButton.title = saved ? "Saved" : "Save"
            resultSaveButton.layer?.backgroundColor = saved
                ? NSColor.disabledControlTextColor.withAlphaComponent(0.3).cgColor
                : NSColor.controlAccentColor.cgColor
            resultSaveButton.alphaValue = saved ? 0.6 : 1
        }
    }

    @objc private func entryTypeClicked(_ sender: NSButton) {
        let types = ["word", "phrase", "pattern"]
        guard let index = entryButtons.firstIndex(of: sender) else { return }
        activeRun?.entryType = types[index]
        updateEntryTypeTags()
    }
    @objc private func inputActionClicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        let isTool = ["copy", "search", "read", "speak", "note", "handoff"].contains(id)
        submitInput(kind: isTool ? "tool" : "feature", id: id)
    }

    func submitInput(kind: String, id: String) {
        FileLog.write("CARD submit id=\(id) kind=\(kind)")
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Speech + builtin tools run in-process; handoff stays on Rust
        // (activation + injection, disabled by default).
        if id == "read" || id == "speak" {
            LexiSpeech.shared.speak(text: text)
            return
        }
        if id == "search" {
            LexiTools.search(text: text)
            return
        }
        if id == "note" {
            LexiTools.note(text: text)
            return
        }
        if kind == "feature" {
            // Empty id = the default feature (Rust parity: first enabled
            // by sort order) — the input bar's Enter submits that way.
            let featureId = id.isEmpty
                ? (LexiStore.features().first(where: { $0.enabled })?.id ?? "")
                : id
            guard !featureId.isEmpty else { return }
            runFeatureLocally(featureId: featureId, text: text)
            inputTextView.string = ""
            layoutResultCard()
            rebuildInputButtons()
            return
        }
        switch id {
        case "copy": LexiTools.copy(text: text)
        case "search": LexiTools.search(text: text)
        case "read", "speak": LexiSpeech.shared.speak(text: text)
        case "note": LexiTools.note(text: text)
        case "handoff": LexiTools.handoff(text: text)
        default: break
        }
        inputTextView.string = ""
        layoutResultCard()
    }

    @objc private func copyResultClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(activeRun?.text ?? "", forType: .string)
        resultCopyButton.title = "Copied"
        resultCopyButton.image = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.resultCopyButton.title = ""
            self?.resultCopyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy result")
        }
    }

    @objc private func saveResultClicked() {
        guard let run = activeRun, let json = run.translationJson else { return }
        let payload: [String: String] = [
            "word": jsonStringField(json, "word") ?? run.title,
            "translation": jsonStringField(json, "translation") ?? "",
            "pos": jsonStringField(json, "pos") ?? "",
            "definition": jsonStringField(json, "definition") ?? "",
            "example": jsonStringField(json, "example") ?? "",
            "entryType": run.entryType,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return }
        handleAction(action: "save-vocab", text: body)
        run.saved = true
        updateEntryTypeTags()
        updateSaveButton()
    }

    func dismissRun(_ id: String) {
        cardRuns.removeAll { $0.id == id }
        if activeRunId == id {
            activeRunId = cardRuns.last?.id
        }
        if cardRuns.isEmpty {
            resultPanel.orderOut(nil)
            return
        }
        rebuildRunTabs()
        renderActiveRun()
        layoutResultCard()
    }

    func jsonStringField(_ json: String, _ field: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[field] as? String
    }
    func inferredEntryType(for word: String) -> String {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") { return "pattern" }
        if text.contains(" ") { return "phrase" }
        return "word"
    }
}

