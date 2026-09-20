import AppKit

// ---------------------------------------------------------------------------
// Result card runs: run-tab chips, input action buttons, entry-type/save
// state, submit/copy/save/dismiss — plus the input text view's
// NSTextViewDelegate conformance. An extension of SelectionToolbarApp.
// ---------------------------------------------------------------------------

extension SelectionToolbarApp: NSTextViewDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === noteSearchField else { return }
        noteSearchText = noteSearchField.stringValue
        applyNoteFilters()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        // AiForm parity: re-measure and re-flow single- vs multi-line on
        // every edit, and re-enable the action buttons when text exists.
        layoutResultCard()
        rebuildInputButtons()
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        setInputFocused(true)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        setInputFocused(false)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputTextView else { return false }
        let newline = NSSelectorFromString("insertNewline:")
        let cancel = NSSelectorFromString("cancelOperation:")
        if commandSelector == newline {
            // Enter runs the default feature; Shift+Enter keeps a newline
            // (WebView AiForm keydown parity).
            if !NSEvent.modifierFlags.contains(.shift) {
                submitInput(kind: "feature", id: "")
                return true
            }
            return false
        }
        if commandSelector == cancel {
            escapeResultCardIfNeeded()
            return true
        }
        return false
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
            button.image = panelIcon(for: item.icon, title: item.name)
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
        entryPicker.isHidden = !hasEntry
        let types = ["word", "phrase", "pattern"]
        let saved = run?.saved == true
        entryPicker.isEnabled = !saved && hasEntry
        entryPicker.alphaValue = saved ? 0.4 : 1
        entryPicker.selectedSegment = hasEntry
            ? (types.firstIndex(of: run?.entryType ?? "word") ?? 0)
            : -1
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

    @objc func entryTypePicked(_ sender: NSSegmentedControl) {
        let types = ["word", "phrase", "pattern"]
        guard sender.selectedSegment >= 0 else { return }
        activeRun?.entryType = types[sender.selectedSegment]
    }
    @objc private func inputActionClicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        submitInput(kind: LexiTools.isTool(id: id) ? "tool" : "feature", id: id)
    }

    func submitInput(kind: String, id: String) {
        FileLog.write("CARD submit id=\(id) kind=\(kind)")
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if kind == "feature" {
            // Empty id = the default feature (first enabled by sort
            // order) — the input bar's Enter submits that way.
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
        // Builtin tools — one dispatch table (same as the toolbar bar).
        LexiTools.run(id: id, text: text)
        // Transient tools (read/search/note) keep the text for follow-ups;
        // copy/handoff consume it.
        if id == "copy" || id == "handoff" {
            inputTextView.string = ""
            layoutResultCard()
        }
    }

    @objc func copyResultClicked() {
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

    @objc func saveResultClicked() {
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
        cardRunTasks.removeValue(forKey: id)?.cancel()
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
