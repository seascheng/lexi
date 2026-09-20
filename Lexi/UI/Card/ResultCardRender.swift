import AppKit

// ---------------------------------------------------------------------------
// Result card rendering: stream event handling, active-run render, markdown
// measurement/coloring, layout pass, and window placement. An extension of
// SelectionToolbarApp.
// ---------------------------------------------------------------------------

extension SelectionToolbarApp {
    func handleResultEvent(_ payload: ResultEventPayload) {
        let runId = payload.runId?.isEmpty == false ? payload.runId! : activeRunId
        guard let run = cardRuns.first(where: { $0.id == runId }) ?? activeRun else { return }

        if let error = payload.error {
            run.status = .error
            run.text = error
        } else if payload.done {
            run.text = payload.chunk ?? run.text
            run.status = .ready
            if let json = payload.translationJson {
                run.translationJson = json
                run.entryType = inferredEntryType(for: jsonStringField(json, "word") ?? run.title)
            }
            if payload.saved == true {
                run.saved = true
            }
        } else if let chunk = payload.chunk {
            run.text += chunk
            run.status = .streaming
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
        resultLoadingIndicator.startAnimation(nil)
    }

    func spinnerStop() {
        resultLoadingIndicator.stopAnimation(nil)
    }

    /// Re-render the active run's content area (loading / streaming / error /
    /// ready) and the action bar state.
    func renderActiveRun() {
        let run = activeRun
        let status = run?.status

        resultLoadingIndicator.isHidden = status != .loading
        if status == .loading {
            spinnerStart()
        } else {
            spinnerStop()
        }
        resultLoadingLabel.isHidden = status != .loading
        translateIdleView.isHidden = activePanel != "translate" || run != nil
        resultScrollView.isHidden = !(status == .streaming || status == .ready || status == .error)
        resultActionBar.isHidden = status != .ready

        if status == .streaming || status == .ready {
            let colors = markdownColors()
            resultTextView.textStorage?.setAttributedString(
                MarkdownText.nsAttributedString(
                    run?.text ?? "", fontSize: 13,
                    baseColor: colors.base,
                    secondaryColor: colors.secondary,
                    codeBackground: colors.codeBg))
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
            if status == .streaming {
                resultTextView.scrollToEndOfDocument(nil)
            }
        } else if status == .error {
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

        if status == .ready {
            updateEntryTypeTags()
            updateSaveButton()
        }
        rebuildRunTabs()
    }

    @objc func pinToggled() {
        cardPinned.toggle()
        resultCloseButton.image = panelIcon(for: cardPinned ? "pin" : "pin-off", title: cardPinned ? "Unpin" : "Pin")
        resultCloseButton.toolTip = cardPinned ? "Unpin" : "Pin"
        resultCloseButton.contentTintColor = cardPinned ? cardTheme.foreground : cardTheme.secondaryText
        log("card pinned=\(cardPinned)")
    }

    func clearAllRuns() {
        cardRunTasks.values.forEach { $0.cancel() }
        cardRunTasks.removeAll()
        cardRuns.removeAll()
        activeRunId = nil
        cardPinned = false
        rebuildRunTabs()
    }


    @objc func clearRunsClicked() {
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
        } else if status == .loading {
            contentH = 48
        } else if status == .streaming || status == .ready || status == .error {
            contentH = min(max(markdownRenderedHeight(activeRun?.text ?? "", atWidth: width - 28) + 24, 64), 440)
        }

        let actionH: CGFloat = (isTranslate && status == .ready) ? 34 : 0

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

        resultScrollView.isHidden = !isTranslate || !(status == .streaming || status == .ready || status == .error)
        resultScrollView.frame = NSRect(x: 0, y: contentY, width: width, height: contentFinal)
        resultLoadingIndicator.isHidden = !isTranslate || status != .loading
        resultLoadingLabel.isHidden = !isTranslate || status != .loading
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
        resultCloseButton.frame.origin.x = width - 32
        resultTrashButton.frame = NSRect(x: width - 30, y: runsY + 3, width: 22, height: 22)
        resultTrashButton.isHidden = runsH == 0
        runsSeparator.isHidden = runsH == 0
        runsSeparator.frame = .zero
        resultRunsBar.isHidden = runsH == 0
        updateEntryTypeTags()
    }

    func markdownRenderedHeight(_ markdown: String, atWidth width: CGFloat) -> CGFloat {
        // Measured with a real NSLayoutManager: NSAttributedString.boundingRect
        // drifts on CJK line heights/paragraph spacing, which cut text off at
        // the bottom of the card.
        let colors = markdownColors()
        let storage = NSTextStorage(attributedString: MarkdownText.nsAttributedString(
            markdown, fontSize: 13,
            baseColor: colors.base,
            secondaryColor: colors.secondary,
            codeBackground: colors.codeBg))
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Markdown surface colors on the card (body/secondary/code-wash).
    func markdownColors() -> (base: NSColor, secondary: NSColor, codeBg: NSColor) {
        let dark = theme == .dark
        return (
            dark ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.85),
            dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.55),
            dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
        )
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
        return Self.textHeight(of: storage, atWidth: width)
    }

    /// Shared NSLayoutManager height measure (exact wrap counts, real
    /// fallback-font line heights).
    static func textHeight(of storage: NSTextStorage, atWidth width: CGFloat) -> CGFloat {
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Rendered height of an attributed string at a width (NSLayoutManager).
    func inputTextHeight(atWidth width: CGFloat, of attributed: NSAttributedString) -> CGFloat {
        Self.textHeight(of: NSTextStorage(attributedString: attributed), atWidth: width)
    }

    func relayoutReview(width: CGFloat, height: CGFloat) {
        let mid = height / 2
        reviewWordLabel.font = .systemFont(ofSize: min(28, max(20, height / 7)), weight: .semibold)
        reviewWordLabel.frame = NSRect(x: 10, y: mid + 16, width: width - 20, height: 34)
        // Answer grows downward from the word, capped at 3 lines — the
        // reveal button and grades keep their slots.
        let answerWidth = width - 48
        let measured = reviewAnswerLabel.attributedStringValue.length == 0
            ? 18
            : inputTextHeight(
                atWidth: answerWidth,
                of: reviewAnswerLabel.attributedStringValue
            )
        let answerHeight = max(18, min(ceil(measured), 51))
        reviewAnswerLabel.frame = NSRect(
            x: 24, y: mid + 10 - answerHeight,
            width: answerWidth, height: answerHeight)
        reviewRevealButton.frame = NSRect(x: width / 2 - 40, y: mid - 44, width: 80, height: 24)
        let gradesW = CGFloat(reviewGradeButtons.count) * 98 - 10
        for (index, grade) in reviewGradeButtons.enumerated() {
            grade.frame = NSRect(x: (width - gradesW) / 2 + CGFloat(index) * 98, y: 16, width: 88, height: 26)
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
