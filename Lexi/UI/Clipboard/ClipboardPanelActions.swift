import AppKit

// Clipboard panel actions: pin/delete, paste, right-click context menus
// (delete / move / rename), keyboard navigation and NSTextFieldDelegate
// command routing. Split out of ClipboardPanel.swift — behavior-preserving
// file split.
extension ClipboardPanelController {

    // MARK: actions

    /// ⌘P lands here via KeyablePanel.keyEquivalentHandler (clipboard tab
    /// only — notes are managed in the ActionPanel / main window).
    func togglePinSelected() {
        guard tab == .clipboard, let store, let item = selectedItem else { return }
        let wasPinned = item.pinnedAt != nil
        store.setPinned(item, pinned: !wasPinned)
        reload()
        // Follow the row to its new position (unpin re-recencies it). The
        // pinned section contributes one header row above the flat list.
        let hasPinnedSection = visibleItems.first?.pinnedAt != nil
        if let newIndex = visibleItems.firstIndex(where: { $0.id == item.id }) {
            selectedRow = newIndex + (hasPinnedSection ? 1 : 0)
        }
        updateFooter()
    }

    /// Double-click lands here: same as Enter — paste through and dismiss.
    @objc func tableDoubleClicked() {
        pasteSelected()
    }



    /// Headless ＋ probe: opens the inline new-category input exactly as
    /// the ＋ button does, logging the chip-row geometry (scroll repro).
    func debugBeginTagCreation() {
        beginTagCreation()
        let clip = chipsScrollView.contentView
        FileLog.write(
            "CLIP-PLUS open input=\(NSStringFromRect(tagInputView.frame))"
                + " doc=\(NSStringFromRect(chipsContent.frame))"
                + " visible=\(NSStringFromRect(clip.documentVisibleRect))")
    }

    /// Headless chip-rename probe: folds a tag's chip into the inline
    /// input exactly as the context-menu 重命名 does.
    func debugBeginTagRename(_ tag: String) {
        beginTagRename(tag)
        let clip = chipsScrollView.contentView
        FileLog.write(
            "CLIP-TAGRENAME input=\(NSStringFromRect(tagInputView.frame))"
                + " doc=\(NSStringFromRect(chipsContent.frame))"
                + " arranged=\(chipsContent.arrangedSubviews.count)")
    }

    /// Headless chips geometry dump (＋ scroll repro, after the settle).
    func debugLogChipsGeometry() {
        let clip = chipsScrollView.contentView
        FileLog.write(
            "CLIP-PLUS after input=\(NSStringFromRect(tagInputView.frame))"
                + " doc=\(NSStringFromRect(chipsContent.frame))"
                + " visible=\(NSStringFromRect(clip.documentVisibleRect))")
    }

    /// The card/toolbar/launcher manage their own visibility. macOS's
    /// NSPanel focus handling (nonactivatingPanel + windowDidResignKey)
    /// handles cross-panel dismissal naturally.

    private func pasteSelected() {
        FileLog.write("PASTE enter tab=\(tab)")
        switch tab {
        case .clipboard:
            pasteClipboardSelection()
        case .tag:
            pasteNoteSelection()
        }
    }

    /// Headless right-click repro: opens the inline rename editor on a note
    /// row exactly as the context-menu item does. Call AFTER a snapshot —
    /// the bitmap render is what materializes the row views headless.
    func debugBeginRename(row: Int) {
        guard rows.indices.contains(row), case .note(let note) = rows[row] else { return }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = "\(note.id)|\(note.name)"
        renameNoteFromMenu(item)
    }

    /// The panel's live first responder (E2E rename probe types into the
    /// field editor it expects to find here).
    func panelFirstResponder() -> NSResponder? {
        panel.firstResponder
    }


    /// Headless snapshot for the /debug-clip-shot route.
    func snapshotPNG() -> Data? {
        panel.contentView?.snapshotPNG()
    }

    /// Headless layout probe for the notes tab: synthetic chips/rows pushed
    /// in-memory, a tag tab opened. The real /card-notes snapshot restores
    /// the state on the next real open.
    func debugShowNotes(notes: [ClipboardNote], categories: [String], tag: String) {
        updateNotes(notes: notes, categories: categories)
        tab = .tag(tag)
        syncChips()
        reload()
        placePanel()
        panel.makeKeyAndOrderFront(nil)
    }


    private func pasteClipboardSelection() {
        guard let store, let item = selectedItem else { return }
        // Write attempt happens BEFORE the panel hides — a vanished file
        // then keeps the panel open with the notice, instead of writing
        // the failure into an already-hidden window.
        ClipboardPaster.paste(item, store: store, previousApp: previousApp) { [weak self] success in
            guard let self else { return }
            if success {
                self.hide(notify: true)
            } else if item.kind == .file {
                // A vanished file is reported, never silently swallowed and
                // never auto-deleted — history is a record of what happened.
                self.showFooterNotice("文件已不存在 — \(item.text ?? "")")
            }
        }
    }

    private func pasteNoteSelection() {
        guard let note = selectedNote else { return }
        hide(notify: true)
        ClipboardPaster.pasteString(note.content, previousApp: previousApp)
    }

    // MARK: management (right-click)

    /// Right-click menus. Clips: delete / move-to-category (saves the clip
    /// as a note under the chosen tag, then removes the clip). Notes: delete
    /// / rename / move-to-category (re-tag via the existing note-tag action).
    func contextMenu(for row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count else { return nil }
        switch rows[row] {
        case .header:
            return nil
        case .clip(let item):
            let menu = NSMenu()
            let delete = NSMenuItem(title: "删除", action: #selector(deleteClipFromMenu(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = item.id.uuidString
            menu.addItem(delete)
            menu.addItem(withTitle: "移动到分类…", action: nil, keyEquivalent: "").submenu = tagSubmenu(
                selector: #selector(moveClipToTagFromMenu(_:)),
                payloadPrefix: item.id.uuidString + "|"
            )
            return menu
        case .note(let note):
            let noteId = note.id
            guard noteId != 0 else { return nil } // 0 = unsaved note (feed sentinel)
            let menu = NSMenu()
            let delete = NSMenuItem(title: "删除", action: #selector(deleteNoteFromMenu(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = String(noteId)
            menu.addItem(delete)
            let rename = NSMenuItem(title: "重命名…", action: #selector(renameNoteFromMenu(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = "\(noteId)|\(note.name)"
            menu.addItem(rename)
            let move = NSMenuItem(title: "移动到分类…", action: nil, keyEquivalent: "")
            move.submenu = tagSubmenu(
                selector: #selector(moveNoteToTagFromMenu(_:)),
                payloadPrefix: "\(noteId)|",
                excluding: note.category
            )
            menu.addItem(move)
            return menu
        }
    }

    private func tagSubmenu(
        selector: Selector, payloadPrefix: String, excluding current: String? = nil
    ) -> NSMenu {
        let submenu = NSMenu()
        for tag in allTags where tag != current {
            let item = NSMenuItem(title: tag, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = payloadPrefix + tag
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            submenu.addItem(withTitle: "暂无其他分类", action: nil, keyEquivalent: "").isEnabled = false
        }
        return submenu
    }

    @objc private func deleteClipFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let store,
              let item = store.items.first(where: { $0.id == id })
        else { return }
        store.delete(item)
        reload()
    }

    /// Move a clip into a note category: create the note server-side, then
    /// remove the clip row. Image/file clips move their text form only.
    @objc private func moveClipToTagFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|"),
              let id = UUID(uuidString: String(payload[..<separator])),
              let tag = payload[payload.index(after: separator)...].isEmpty
                ? nil : String(payload[payload.index(after: separator)...]),
              let store,
              let item = store.items.first(where: { $0.id == id }),
              let content = item.previewText
        else { return }
        let body: [String: String] = ["name": "", "content": content, "tag": tag]
        if let data = try? JSONSerialization.data(withJSONObject: body),
           let json = String(data: data, encoding: .utf8) {
            onAction?("note-create", json)
        }
        store.delete(item)
        reload()
    }

    @objc private func deleteNoteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onAction?("note-delete", id)
    }

    @objc private func renameNoteFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|") else { return }
        let noteId = Int64(String(payload[..<separator])) ?? 0
        let current = String(payload[payload.index(after: separator)...])
        guard noteId != 0,
              let row = rows.indices.first(where: {
                  if case .note(let note) = rows[$0] { return note.id == noteId }
                  return false
              }),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ClipCell
        else { return }
        // Index BEFORE the session: the row-height re-ask it triggers goes
        // through heightOfRow, which reads this.
        renamingRow = row
        cell.beginRenaming(
            current: current,
            onCommit: { [weak self] newName in
                guard let self else { return }
                let body: [String: Any] = ["id": noteId, "name": newName]
                if let data = try? JSONSerialization.data(withJSONObject: body),
                   let json = String(data: data, encoding: .utf8) {
                    self.onAction?("note-rename", json)
                }
            },
            onEnd: { [weak self] in
                self?.renamingRow = nil
            })
    }

    @objc private func moveNoteToTagFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|") else { return }
        let id = String(payload[..<separator])
        let tag = String(payload[payload.index(after: separator)...])
        onAction?("note-tag", "\(id)|\(tag)")
    }


    // MARK: keyboard

    private func moveVertical(_ delta: Int) {
        let selectable = rows.indices.filter {
            if case .header = rows[$0] { return false }
            return true
        }
        guard !selectable.isEmpty else { return }
        let current = tableView.selectedRow
        let next: Int
        if current >= 0, let position = selectable.firstIndex(of: current) {
            next = selectable[min(max(position + delta, 0), selectable.count - 1)]
        } else {
            next = delta > 0 ? selectable[0] : selectable[selectable.count - 1]
        }
        selectedRow = next
        updateFooter()
    }

    /// Tab cycles the chip tabs (the ⊕ chip is a separate view, not a tab).
    func cycleTabs(_ delta: Int) {
        let kinds = chipViews.map(\.kind)
        guard let index = kinds.firstIndex(of: activeChipKind) else { return }
        let next = kinds[(index + delta + kinds.count) % kinds.count]
        switch next {
        case .clipboard:
            selectTab(.clipboard)
        case .tag(let name):
            selectTab(.tag(name))
        }
    }

    // NSTextFieldDelegate — the search field and the inline tag input share
    // this delegate; route by sender.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let isTagInput = control === tagInputField
        switch commandSelector {
        case NSSelectorFromString("moveUp:"):
            if !isTagInput {
                moveVertical(-1)
                return true
            }
            return false
        case NSSelectorFromString("moveDown:"):
            if !isTagInput {
                moveVertical(1)
                return true
            }
            return false
        case NSSelectorFromString("insertNewline:"):
            if isTagInput {
                commitTagInput()
                return true
            }
            pasteSelected()
            return true
        case NSSelectorFromString("cancelOperation:"):
            if isTagInput {
                endTagInput() // cancel: fold back to the ＋ chip
                return true
            }
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            } else {
                hide(notify: true)
            }
            return true
        case NSSelectorFromString("moveLeft:"):
            // Arrow keys switch tabs in the same context Tab does (the
            // search field owns the panel keyboard); inside the tag input
            // they move the caret.
            if !isTagInput {
                cycleTabs(-1)
                return true
            }
            return false
        case NSSelectorFromString("moveRight:"):
            if !isTagInput {
                cycleTabs(1)
                return true
            }
            return false
        case NSSelectorFromString("insertTab:"):
            // Tab cycles the chip tabs from EITHER field.
            cycleTabs(1)
            return true
        default:
            // Arrows inside the tag input move the caret; arrows in the
            // search field are handled above.
            return false
        }
    }

    // NSTextFieldDelegate — search drives the list; the tag input is inert
    // until Enter (commitTagInput).
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) !== tagInputField else { return }
        reload()
    }
}
