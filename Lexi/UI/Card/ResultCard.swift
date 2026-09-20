import AppKit

// ---------------------------------------------------------------------------
// Result card: build + panel-tab/note-filter/tag-bar plumbing for the
// streaming AI answer surface. An extension of SelectionToolbarApp; stored
// state stays in the class body in SelectionToolbarHelper.swift.
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
        resultPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Arrow keys walk the review deck (← back, → next). Only the
        // review tab consumes them; every other tab falls through.
        resultPanel.keyEquivalentHandler = { [weak self] event in
            guard let self, event.type == .keyDown else { return false }
            switch event.keyCode {
            case 123: self.reviewStep(-1); return true
            case 124: self.reviewStep(1); return true
            default: return false
            }
        }
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

        buildPanelTabPills()

        // Pin toggle (WebView FloatingFrame parity): unpinned = dismisses on
        // outside click / Esc; pinned = stays. Replaces the close button —
        // closing happens by unpinning, then clicking away.
        resultCloseButton = NSButton(title: "", target: self, action: #selector(pinToggled))
        resultCloseButton.bezelStyle = .regularSquare
        resultCloseButton.isBordered = false
        resultCloseButton.image = panelIcon(for: "pin-off", title: "Pin")
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
        resultTrashButton.image = panelIcon(for: "x", title: "Close all results")
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
        resultLoadingIndicator.controlSize = .small
        resultLoadingIndicator.style = .spinning
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
        resultIdleIcon.image = panelIcon(for: "sparkles", title: "Idle")
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

        // Word/Phrase/Pattern picker: native single-choice segments —
        // selection highlight, sizing and keyboard handling are free.
        entryPicker = NSSegmentedControl(
            labels: ["Word", "Phrase", "Pattern"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(entryTypePicked(_:)))
        entryPicker.segmentStyle = .capsule
        entryPicker.controlSize = .small
        entryPicker.sizeToFit()
        resultActionBar.addSubview(entryPicker)

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

        reviewAnswerLabel = NSTextField(wrappingLabelWithString: "")
        reviewAnswerLabel.font = .systemFont(ofSize: 13)
        reviewAnswerLabel.textColor = cardTheme.secondaryText
        reviewAnswerLabel.alignment = .natural
        reviewAnswerLabel.cell?.truncatesLastVisibleLine = true
        reviewAnswerLabel.frame = NSRect(x: 24, y: 88, width: resultCardWidth - 48, height: 18)
        reviewCardView.addSubview(reviewAnswerLabel)

        reviewRevealButton = NSButton(title: "Reveal", target: self, action: #selector(revealReviewClicked))
        reviewRevealButton.bezelStyle = .rounded
        reviewRevealButton.controlSize = .regular
        reviewRevealButton.frame = NSRect(x: resultCardWidth / 2 - 40, y: 48, width: 80, height: 24)
        reviewCardView.addSubview(reviewRevealButton)

        let gradeStyles: [(String, NSColor, String)] = [
            ("Again", .systemRed, "arrow.counterclockwise"),
            ("Hard", .systemOrange, "hand.thumbsdown"),
            ("Good", .systemBlue, "checkmark"),
            ("Easy", .systemGreen, "checkmark.circle.fill"),
        ]
        for (index, style) in gradeStyles.enumerated() {
            let grade = NSButton(title: style.0, target: self, action: #selector(gradeClicked(_:)))
            grade.bezelStyle = .rounded
            // Filled color capsule (white title/symbol on the tint), same
            // look as the settings pane's grade row — one state, always on.
            grade.bezelColor = style.1
            if let icon = NSImage(systemSymbolName: style.2, accessibilityDescription: nil) {
                grade.image = icon
                grade.imagePosition = .imageLeading
            }
            grade.font = .systemFont(ofSize: 12, weight: .medium)
            grade.tag = index
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

    var activeRun: CardRun? {
        cardRuns.first { $0.id == activeRunId } ?? cardRuns.last
    }

    func showResultCard(_ payload: ResultShowPayload) {
        sourceApp = NSWorkspace.shared.frontmostApplication
        FileLog.write("CARD open=api runId=\(payload.runId ?? "-") feature=\(payload.featureId ?? "-") input=\(payload.inputText?.prefix(24) ?? "-")")
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
        noteTagBar.subviews.forEach { $0.removeFromSuperview() }
        let names = ["all"] + cardCategories
        // Native single-choice segments: All + one per category.
        let picker = NSSegmentedControl(
            labels: names.map { $0 == "all" ? "All" : $0.capitalized },
            trackingMode: .selectOne,
            target: self,
            action: #selector(noteTagPicked(_:)))
        picker.segmentStyle = .capsule
        picker.controlSize = .small
        picker.sizeToFit()
        if let index = names.firstIndex(of: noteActiveCategory) {
            picker.selectedSegment = index
        }
        noteTagPicker = picker
        noteTagBar.addSubview(picker)
        layoutResultCard()
    }

    /// The picker hugs its labels inside the positioned bar.
    func layoutNoteTagButtons() {
        noteTagPicker?.frame.origin = NSPoint(x: 0, y: -2)
    }

    @objc func noteTagPicked(_ sender: NSSegmentedControl) {
        let names = ["all"] + cardCategories
        guard sender.selectedSegment >= 0, sender.selectedSegment < names.count else { return }
        noteActiveCategory = names[sender.selectedSegment]
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
            button.layer?.cornerRadius = PanelDesign.pillCornerRadius
            button.attributedTitle = tabPillTitle(def)
            cardPanelTabsView.addSubview(button)
            panelTabPills.append(button)
        }
        layoutPanelTabPills()
        stylePanelTabPills()
    }

    /// Icon + label as one attributed title — NSButton's imageLeading
    /// spacing is untamable. Active content is WHITE on the system
    /// selection blue; inactive is the quiet secondary tint.
    func tabPillTitle(_ def: (id: String, name: String, icon: String), active: Bool = false) -> NSAttributedString {
        let content = active ? NSColor.white : cardTheme.secondaryText
        let title = NSMutableAttributedString(string: " ")
        if let icon = panelIcon(for: def.icon, title: def.name, color: content) {
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
            .foregroundColor: content,
        ]))
        return title
    }
    func layoutPanelTabPills() {
        panelTabPills.forEach { $0.sizeToFit() }
        // Text-adaptive widths with one uniform padding: 6pt per side
        // (≈ the vertical (26−14)/2) — the same rule the launcher and
        // clipboard tab chips follow.
        let widths = panelTabPills.map { max($0.frame.width + 12, 44) }
        let total = widths.reduce(0, +) + CGFloat(max(panelTabPills.count - 1, 0)) * 6
        var x = max((cardPanelTabsView.bounds.width - total) / 2, 0)
        for (pill, w) in zip(panelTabPills, widths) {
            pill.frame = NSRect(x: x, y: 2, width: w, height: 26)
            x += w + 6
        }
    }

    func stylePanelTabPills() {
        for pill in panelTabPills {
            let def = panelDefs.first { $0.id == pill.identifier?.rawValue }
            let active = pill.identifier?.rawValue == activePanel
            pill.attributedTitle = def.map { tabPillTitle($0, active: active) } ?? pill.attributedTitle
            // Template attachments tint through the button; the attributed
            // text carries its own color — both must agree.
            pill.contentTintColor = active ? .white : cardTheme.secondaryText
            // The system selection blue with white content — the same
            // selected grammar every list and tab in the app now uses.
            pill.layer?.backgroundColor = active
                ? NSColor.selectedContentBackgroundColor.cgColor
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
}

