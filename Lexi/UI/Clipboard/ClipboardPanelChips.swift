import AppKit

// Chip tab row: rebuild/select, drag-to-reorder, tag create/rename input,
// and the chip management menus (color/rename/delete). Split out of
// ClipboardPanel.swift — behavior-preserving file split.
extension ClipboardPanelController {

    /// Chip tab row: [Clipboard] + one chip per tag + ＋, laid out by the
    /// stack. Rebuilt whenever the notes snapshot arrives.
    func rebuildChips() {
        // Keep the user's horizontal place: the notes push rebuilds the
        // whole row, and a torn-down document resets the clip view to
        // its origin.
        let savedX = chipsScrollView.contentView.bounds.origin.x
        // The stack owns the flow; this only (re)populates arranged views.
        chipsContent.arrangedSubviews.forEach(chipsContent.removeArrangedSubview)
        chipsContent.subviews.forEach { $0.removeFromSuperview() }
        chipViews.removeAll()

        for tag in allTags {
            let view = ChipPillView(frame: .zero)
            let color = tagChipColor(named: tag)
            view.configure(title: tag, color: color) { [weak self] in
                self?.selectTab(.tag(tag))
            }
            // applyTheme AFTER configure: configure re-applies the stored
            // (stale) theme — the /card-notes push rebuilds chips while the
            // panel is light, and the stale dark theme painted unreadable
            // white labels.
            view.applyTheme(cardTheme)
            view.isDraggable = true
            view.onDragBegin = { [weak self] chip, event in self?.beginChipDrag(chip, event: event) }
            view.onDragMove = { [weak self] chip, event in self?.updateChipDrag(chip, event: event) }
            view.onDragEnd = { [weak self] _ in self?.endChipDrag() }
            if tag != Self.defaultTag {
                // The uncategorized bucket is a pseudo tab — no management.
                view.onMenu = { [weak self] in self?.chipMenu(for: tag) }
            }
            chipViews.append((.tag(tag), view))
        }

        let clipboard = ChipPillView(frame: .zero)
        clipboard.configure(title: "剪贴板", color: .systemGray) { [weak self] in
            self?.selectTab(.clipboard)
        }
        clipboard.applyTheme(cardTheme)
        chipViews.insert((.clipboard, clipboard), at: 0)

        for (_, view) in chipViews {
            chipsContent.addArrangedSubview(view)
        }
        addChip.isHidden = false
        chipsContent.addArrangedSubview(addChip)
        refitChipsRow()
        chipsContent.layoutSubtreeIfNeeded() // final document width first
        let clip = chipsScrollView.contentView
        let maxX = max(0, chipsContent.frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(savedX, maxX), y: 0))
        chipsScrollView.reflectScrolledClipView(clip)
        syncChips()
    }

    func selectTab(_ tab: Tab) {
        guard self.tab != tab else { return }
        self.tab = tab
        searchField.stringValue = ""
        syncChips()
        reload()
        // A new tab starts reading from its first row — reload() only clamps
        // the offset (to preserve position on same-tab refreshes).
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: chip drag reorder (stack-native: detached chip + gap spacer)


    /// The dragged chip detaches from the flow (free-floating above), the
    /// spacer opens its slot; neighbours flow around the live slot. The
    /// Clipboard tab stays pinned first — dragged chips never cross it.
    private func beginChipDrag(_ chip: ChipPillView, event: NSEvent) {
        guard let entry = chipViews.first(where: { $0.view === chip }),
              entry.kind != .clipboard,
              let index = chipsContent.arrangedSubviews.firstIndex(of: chip)
        else { return }
        dragChip = chip
        dragGrabOffset = chip.convert(event.locationInWindow, from: nil).x
        chipsContent.removeArrangedSubview(chip)
        chipsContent.insertArrangedSubview(dragSpacer, at: index)
        // Raise above siblings for the whole drag (plain subview: the
        // stack no longer positions it).
        chipsContent.addSubview(chip, positioned: .above, relativeTo: nil)
    }

    private func updateChipDrag(_ chip: ChipPillView, event: NSEvent) {
        guard let dragged = dragChip, dragged === chip else { return }
        let xInContent = chip.superview.map { $0.convert(event.locationInWindow, from: nil).x }
            ?? chip.frame.origin.x
        let contentWidth = chipsContent.frame.width
        let rawX = xInContent - dragGrabOffset
        // Clamp within the row: never before the Clipboard chip (index 0).
        let minX = chipViews.first?.view.frame.maxX ?? 0
        chip.frame.origin.x = min(max(rawX, minX), contentWidth - chip.frame.width)

        // Live slot by the chip's center: move the spacer; the stack
        // reflows the rest. Clipboard stays pinned at index 0.
        let center = chip.frame.midX
        let arranged = chipsContent.arrangedSubviews.filter { $0 !== chip }
        var slot = arranged.count
        for (index, view) in arranged.enumerated()
        where view !== dragSpacer && view.frame.midX > center {
            slot = index
            break
        }
        let bounded = max(1, min(slot, arranged.count)) // index 0 is Clipboard's
        if let current = chipsContent.arrangedSubviews.firstIndex(of: dragSpacer),
           current != bounded {
            chipsContent.removeArrangedSubview(dragSpacer)
            chipsContent.insertArrangedSubview(dragSpacer, at: bounded)
        }
        // Keep the model in step with the visual slot.
        guard let entry = chipViews.first(where: { $0.view === chip }) else { return }
        var others = chipViews.filter { $0.view !== chip }
        if bounded <= others.count {
            others.insert(entry, at: bounded)
        } else {
            others.append(entry)
        }
        if let clipboardIndex = others.firstIndex(where: {
            if case .clipboard = $0.kind { return true }
            return false
        }), clipboardIndex != 0 {
            let clipboardEntry = others.remove(at: clipboardIndex)
            others.insert(clipboardEntry, at: 0)
        }
        chipViews = others
    }

    private func endChipDrag() {
        guard let dragged = dragChip else { return }
        if let slot = chipsContent.arrangedSubviews.firstIndex(of: dragSpacer) {
            chipsContent.removeArrangedSubview(dragSpacer)
            chipsContent.insertArrangedSubview(dragged, at: slot)
        } else {
            chipsContent.addArrangedSubview(dragged)
        }
        refitChipsRow()
        // Persist the new tag order (Clipboard excluded from the payload).
        let names = chipViews.compactMap { kind, _ -> String? in
            if case .tag(let name) = kind { return name }
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: names),
              let json = String(data: data, encoding: .utf8)
        else { return }
        onAction?("note-tag-reorder", json)
    }

    /// Scrolls ONLY when the target is outside the visible rect — a normal
    /// scroller never moves for things you can already see. The target is
    /// scene-driven: tab switch → the active chip; ＋ click → the input;
    /// fold-back → nothing (keep the user's position).
    private func scrollChipVisible(_ view: NSView) {
        let frame = view.frame
        let visible = chipsScrollView.contentView.documentVisibleRect
        guard frame.minX < visible.minX || frame.maxX > visible.maxX else { return }
        let target = frame.minX < visible.minX
            ? max(0, frame.minX - 12)
            : max(0, min(frame.maxX - visible.width + 12,
                         chipsContent.frame.width - visible.width))
        chipsScrollView.contentView.scroll(to: NSPoint(x: target, y: 0))
        chipsScrollView.reflectScrolledClipView(chipsScrollView.contentView)
    }

    func scrollActiveChipVisible() {
        guard let index = chipViews.firstIndex(where: { $0.kind == activeChipKind }) else { return }
        scrollChipVisible(chipViews[index].view)
    }
    /// ＋ button action: the input becomes the row's LAST arranged view
    /// (the ＋ hides — a hidden arranged view gives up its footprint, the
    /// stack closes the gap on its own).
    @objc func addChipClicked() {
        beginTagCreation()
    }

    func beginTagCreation() {
        addChip.isHidden = true
        tagInputView.isHidden = false
        tagInputView.field.placeholderString = "新分类"
        chipsContent.addArrangedSubview(tagInputView)
        refitChipsRow()
        chipsContent.layoutSubtreeIfNeeded() // the stack lays out on the pass
        scrollChipVisible(tagInputView)
        panel.makeFirstResponder(tagInputField)
    }

    /// Chip 重命名: the chip hides (footprint collapses) and the input
    /// takes its exact index in the stack — neighbours can never slide
    func beginTagRename(_ tag: String) {
        guard let entry = chipViews.first(where: {
            if case .tag(let name) = $0.kind { return name == tag }
            return false
        }) else { return }
        tagRenameTarget = tag
        tagInputView.isHidden = false
        tagInputView.field.placeholderString = tag
        tagInputView.stringValue = tag
        let index = chipsContent.arrangedSubviews.firstIndex(of: entry.view) ?? chipsContent.arrangedSubviews.count
        entry.view.isHidden = true
        chipsContent.insertArrangedSubview(tagInputView, at: index)
        refitChipsRow()
        chipsContent.layoutSubtreeIfNeeded() // the stack lays out on the pass
        scrollChipVisible(tagInputView)
        panel.makeFirstResponder(tagInputField)
        tagInputField.currentEditor()?.selectAll(nil)
    }

    private var renamedChipView: ChipPillView? {
        guard let target = tagRenameTarget else { return nil }
        return chipViews.first {
            if case .tag(let name) = $0.kind { return name == target }
            return false
        }?.view
    }

    /// Esc / commit cleanup: fold the input back into the ＋ button and
    /// restore the renamed chip.
    func endTagInput() {
        tagInputView.stringValue = ""
        chipsContent.removeArrangedSubview(tagInputView)
        tagInputView.removeFromSuperview()
        tagInputView.isHidden = true
        addChip.isHidden = false
        renamedChipView?.isHidden = false
        tagRenameTarget = nil
        refitChipsRow()
    }

    /// Enter in the inline input: rename the target tag, or create a new
    /// category and switch to it.
    func commitTagInput() {
        let name = tagInputView.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            endTagInput()
            return
        }
        guard name.count <= 24 else {
            showFooterNotice("分类名过长（最多 24 个字符）")
            return // keep the input open for a shorter name
        }
        if let target = tagRenameTarget {
            guard name != target else {
                endTagInput()
                return
            }
            endTagInput()
            if tab == .tag(target) {
                tab = .tag(name)
            }
            onAction?("note-tag-rename", "\(target)|\(name)")
            reload()
            return
        }
        endTagInput()
        // Switch optimistically so the panel is already on the fresh,
        // empty category; the notes push confirms the chip.
        tab = .tag(name)
        syncChips()
        onAction?("note-tag-create", name)
        reload()
    }

    // MARK: tab chip management menu

    /// Stored chip color first, hash color otherwise. Colors ride the
    /// notes-push cache — no per-chip SELECT.
    func tagChipColor(named tag: String) -> NSColor {
        if let hex = tagHexColors[tag], !hex.isEmpty,
           let color = NSColor(lexiHex: hex) {
            return color
        }
        return vividTagColor(for: tag, dark: cardTheme.isDark)
    }

    private func chipMenu(for tag: String) -> NSMenu {
        let menu = NSMenu()

        let rename = NSMenuItem(
            title: "重命名…", action: #selector(renameTagFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = tag
        menu.addItem(rename)

        let color = NSMenuItem(title: "换颜色…", action: nil, keyEquivalent: "")
        color.submenu = tagColorSubmenu(for: tag)
        menu.addItem(color)

        menu.addItem(.separator())
        let delete = NSMenuItem(
            title: "删除分类及笔记", action: #selector(deleteTagFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = tag
        menu.addItem(delete)
        return menu
    }

    private func tagColorSubmenu(for tag: String) -> NSMenu {
        let palette: [(String, String)] = [
            ("蓝", "#3478F6"), ("紫", "#AF52DE"), ("粉", "#FF2D55"),
            ("红", "#FF3B30"), ("橙", "#FF9500"), ("黄", "#FFCC00"),
            ("绿", "#34C759"), ("青", "#5AC8FA"),
        ]
        let submenu = NSMenu()
        let current = tagHexColors[tag] ?? ""
        for (name, hex) in palette {
            let item = NSMenuItem(
                title: name, action: #selector(colorTagFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(tag)|\(hex)"
            item.attributedTitle = Self.swatchTitle(
                hex: hex, name: name)
            item.state = current == hex ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let reset = NSMenuItem(
            title: "恢复默认", action: #selector(colorTagFromMenu(_:)), keyEquivalent: "")
        reset.target = self
        reset.representedObject = "\(tag)|"
        reset.state = current.isEmpty ? .on : .off
        submenu.addItem(reset)
        return submenu
    }

    /// Menu row title with an inline color chip. Rendered as a text
    /// attachment — menus always draw attributed titles, so the swatch
    /// rides the one rendering path that cannot be skipped.
    private static func swatchTitle(hex: String, name: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = colorSwatch(hex: hex)
        // Center the swatch on the label's optical middle (cap height) —
        // the same rule the card's tab-pill icons use.
        let font = NSFont.menuFont(ofSize: 0)
        attachment.bounds = NSRect(
            x: 0, y: (font.capHeight - 13) / 2,
            width: 13, height: 13
        )
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: "  \(name)", attributes: [.font: font]))
        return title
    }

    /// Headless probe entry: the exact submenu the 换颜色 item shows.
    func debugColorMenu(for tag: String) -> NSMenu {
        tagColorSubmenu(for: tag)
    }

    /// skip lazily-drawn (drawingHandler) images.
    private static func colorSwatch(hex: String) -> NSImage {
        let side: CGFloat = 14
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (NSColor(lexiHex: hex) ?? .systemGray).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 1, y: 1, width: side - 2, height: side - 2),
            xRadius: 4, yRadius: 4
        ).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    @objc private func renameTagFromMenu(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        beginTagRename(tag)
    }

    @objc private func deleteTagFromMenu(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        if tab == .tag(tag) {
            tab = .clipboard
            syncChips()
        }
        onAction?("note-tag-delete", tag)
        reload()
    }

    @objc private func colorTagFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|") else { return }
        let tag = String(payload[..<separator])
        let hex = String(payload[payload.index(after: separator)...])
        onAction?("note-tag-color", payload)
        // Optimistic re-tint; the notes push re-renders the chips anyway.
        if let entry = chipViews.first(where: {
            if case .tag(let name) = $0.kind { return name == tag }
            return false
        }) {
            entry.view.configure(title: tag, color: tagChipColor(named: tag)) { [weak self] in
                self?.selectTab(.tag(tag))
            }
            entry.view.applyTheme(cardTheme)
        }
    }
}
