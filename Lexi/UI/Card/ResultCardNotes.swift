import AppKit

// ---------------------------------------------------------------------------
// Result card Notes/Review tabs: note list plumbing (tag menu, delete,
// rename, hover-clear) and the review flashcard flow (load/reveal/grade).
// An extension of SelectionToolbarApp.
// ---------------------------------------------------------------------------

extension SelectionToolbarApp {
    /// Card review tab: fetch the next due word from the shared DB.
    func loadReviewWord() {
        // The outgoing card goes on the back log for ← navigation;
        // popping back re-shows it without re-pushing (skip flag).
        if !reviewSkipPush, reviewCurrentWordId != 0 {
            reviewBackLog.append(CardReviewPayload(word: .init(
                id: reviewCurrentWordId, word: reviewWordLabel.stringValue,
                translation: reviewAnswerMarkdown, pos: nil, entryType: nil)))
        }
        reviewSkipPush = false
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
        // One query per push feeds every row's tag colors.
        cardTagHexColors = Dictionary(
            LexiStore.noteCategories().map { ($0.name, $0.color) },
            uniquingKeysWith: { a, _ in a })
        notesTableView.reloadData()
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
    @objc func notesTableClicked(_ sender: NSTableView) {
        setInputFocused(false)
    }
    // picker is an in-card dropdown layer instead: same material, opens at
    // the pill, click-outside/Esc closes, picking posts note-tag.


    func showTagMenu(noteId: Int64, tag: String?, anchor: NSView) {
        guard noteId != 0 else { return }
        let categories = cardCategories.isEmpty
            ? Array(Set(cardNotesItems.compactMap { $0.category })).sorted()
            : cardCategories
        // Native menu: checkmark on the current tag, divider, clear row;
        // Esc / click-outside dismissal and hover come for free.
        let menu = NSMenu()
        for name in categories {
            let item = NSMenuItem(title: name, action: #selector(tagPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(noteId)|\(name)"
            item.state = name == tag ? .on : .off
            menu.addItem(item)
        }
        if !categories.isEmpty {
            menu.addItem(.separator())
        }
        let clear = NSMenuItem(title: "No tag", action: #selector(tagPicked(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = "\(noteId)|"
        clear.state = tag == nil ? .on : .off
        menu.addItem(clear)
        menu.popUp(positioning: nil, at: anchor.bounds.origin, in: anchor)
    }

    @objc private func tagPicked(_ sender: NSMenuItem) {
        handleAction(action: "note-tag", text: sender.representedObject as? String ?? "")
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
            reviewCurrentWordId = 0
            layoutResultCard()
            return
        }
        reviewEmptyLabel.isHidden = true
        reviewRevealButton.isHidden = false
        reviewCurrentWordId = word.id
        reviewWordLabel.stringValue = word.word
        reviewAnswerLabel.attributedStringValue = NSAttributedString(string: "")
        reviewAnswerMarkdown = word.translation ?? ""
        reviewRevealButton.isEnabled = true
        reviewRevealButton.title = "Reveal"
    }

    @objc func revealReviewClicked() {
        guard reviewCurrentWordId != 0 else { return }
        // Full markdown: bold/italic/lists render properly instead of the
        // raw asterisks a plain stringValue used to show.
        let colors = markdownColors()
        reviewAnswerLabel.attributedStringValue = MarkdownText.nsAttributedString(
            reviewAnswerMarkdown, fontSize: 13,
            baseColor: cardTheme.secondaryText,
            secondaryColor: cardTheme.tertiaryText,
            codeBackground: colors.codeBg)
        reviewRevealButton.isEnabled = false
        layoutResultCard()
    }

    /// Debug-probe hook for the review md rendering (same path as Reveal).
    func debugRevealReview() {
        revealReviewClicked()
    }

    @objc func gradeClicked(_ sender: NSButton) {
        let ratings = ["again", "hard", "good", "easy"]
        guard reviewCurrentWordId != 0 else { return }
        loadReviewWord()
    }
    /// Arrow-key card navigation: ← previous, → next (review tab only).
    func reviewStep(_ delta: Int) {
        guard activePanel == "review" else { return }
        if delta < 0 {
            guard let prev = reviewBackLog.popLast() else { return }
            reviewSkipPush = true
            handleCardReview(prev)
        } else {
            loadReviewWord()
        }
    }
}

extension SelectionToolbarApp {
    /// Hovers are the only self-drawn effect; scrolling invalidates them.
    @objc func notesClipScrolled() {
        let range = notesTableView.rows(in: notesTableView.visibleRect)
        for row in range.location..<max(range.location, range.location + range.length) {
            if let rowView = notesTableView.rowView(atRow: row, makeIfNecessary: false) as? NoteRowView {
                rowView.clearHover()
            }
        }
    }
}

extension SelectionToolbarApp: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === noteSearchField else { return false }
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            if !noteSearchField.stringValue.isEmpty {
                noteSearchField.stringValue = ""
                noteSearchText = ""
                applyNoteFilters()
            } else {
                notesTableView.window?.makeFirstResponder(notesTableView)
            }
            return true
        }
        return false
    }
}

extension SelectionToolbarApp: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedNotes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < displayedNotes.count else { return nil }
        let cell = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("NoteRow"),
            owner: self
        ) as? NoteRowCell ?? NoteRowCell(frame: .zero)
        cell.identifier = NSUserInterfaceItemIdentifier("NoteRow")
        let note = displayedNotes[row]
        cell.configure(note: note, dark: theme == .dark,
                       tagHexColors: cardTagHexColors,
                       onDelete: { [weak self] id in
                           self?.noteDeleteClickedId(id)
                       },
                       onRename: { [weak self] id, name in
                           self?.noteRenamed(id: id, name: name)
                       },
                       onTagPicked: { [weak self] id, anchor in
                           self?.showTagMenu(noteId: id, tag: note.category, anchor: anchor)
                       })
        cell.themeColors = cardTheme
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("NoteRowView"),
            owner: self
        ) as? NoteRowView {
            return reused
        }
        let view = NoteRowView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("NoteRowView")
        view.hoverColor = cardTheme.hoverFill
        view.pillColor = cardTheme.selectedFill
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        FileLog.write("SEL didChange row=\(notesTableView.selectedRow)")
        let selected = notesTableView.selectedRow
        if selected >= 0, selected < displayedNotes.count {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(displayedNotes[selected].content, forType: .string)
        }
    }
}

