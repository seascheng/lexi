import AppKit

// Data plumbing for the clipboard panel: selection accessors, reload /
// reloadClipboard / reloadNotes, footer + empty-state text, table
// data source & delegate (rows, heights, cells, drag-reorder), thumbnail
// cache. Split out of ClipboardPanel.swift — behavior-preserving file split.
extension ClipboardPanelController {

    var selectedRow: Int {
        get { tableView.selectedRow }
        set {
            guard newValue >= 0, rows.indices.contains(newValue) else { return }
            tableView.selectRowIndexes(IndexSet(integer: newValue), byExtendingSelection: false)
            tableView.scrollRowToVisible(newValue)
        }
    }

    var selectedItem: ClipboardItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .clip(let item) = rows[row] else { return nil }
        return item
    }

    var selectedNote: ClipboardNote? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .note(let note) = rows[row] else { return nil }
        return note
    }

    /// - Parameter preservingSelection: data refreshes (the notes push
    /// after rename/move/…) keep the selection on the same item; the
    /// default (tab switch, panel open) lands on the first row.
    func reload(preservingSelection: Bool = false, revealActiveChip: Bool = true) {
        renamingRow = nil
        var selectedNoteID: Int64?
        var selectedClipID: UUID?
        let selectedRow = tableView.selectedRow
        if preservingSelection, rows.indices.contains(selectedRow) {
            switch rows[selectedRow] {
            case .note(let note): selectedNoteID = note.id
            case .clip(let item): selectedClipID = item.id
            case .header: break
            }
        }
        switch tab {
        case .clipboard:
            reloadClipboard()
        case .tag(let tag):
            reloadNotes(tag: tag)
        }
        tableView.reloadData()
        updateFooter()
        updateEmptyState()
        if revealActiveChip {
            scrollActiveChipVisible()
        }
        var target: Int?
        if let id = selectedNoteID {
            target = rows.indices.first {
                if case .note(let note) = rows[$0] { return note.id == id }
                return false
            }
        } else if let id = selectedClipID {
            target = rows.indices.first {
                if case .clip(let item) = rows[$0] { return item.id == id }
                return false
            }
        }
        if target == nil {
            target = rows.indices.first {
                if case .header = rows[$0] { return false }
                return true
            }
        }
        if let target {
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        }
        // Fixed window: never re-place on reload — tab switches must not
        // move the panel off its pinned top-left corner.
        // reloadData tiles the table against the PREVIOUS clip bounds;
        let viewport = scrollView.contentSize
        let contentHeight = tableView.numberOfRows > 0
            ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
            : 0
        tableView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: max(contentHeight, viewport.height))
        let clip = scrollView.contentView
        let maxOffset = max(0, tableView.frame.height - viewport.height)
        if clip.bounds.origin.y > maxOffset {
            clip.scroll(to: NSPoint(x: 0, y: maxOffset))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func reloadClipboard() {
        guard let store else {
            rows = []
            visibleItems = []
            return
        }
        let found = store.search(searchField.stringValue)
        // Pinned items pin to the top as a section: pinned rows live in
        // their section header block; recency rows follow unwrapped.
        let pinned = found.prefix { $0.pinnedAt != nil }
        let rest = found.dropFirst(pinned.count)
        rows = []
        if !pinned.isEmpty {
            rows.append(.header("置顶"))
            rows += pinned.map { Row.clip($0) }
        }
        rows += rest.map { Row.clip($0) }
        visibleItems = Array(found)
    }

    private func reloadNotes(tag: String) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        // Manual order first (drag-reorder); equal sort keys keep the
        // feed's recency order (enumerated offsets — Swift's sort is not
        // stable).
        let matching = notes.enumerated()
            .filter { _, note in
                let inTag = note.category == tag
                    || (note.category == nil && tag == Self.defaultTag)
                guard inTag else { return false }
                guard !query.isEmpty else { return true }
                let haystack = "\(note.name)\n\(note.content)".lowercased()
                return haystack.contains(query)
            }
            .sorted {
                $0.element.sort != $1.element.sort
                    ? $0.element.sort < $1.element.sort
                    : $0.offset < $1.offset
            }
            .map(\.element)
        visibleItems = []
        rows = matching.map { Row.note($0) }
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !rows.isEmpty
        switch tab {
        case .clipboard:
            emptyLabel.stringValue = searchField.stringValue.isEmpty
                ? "暂无粘贴板历史 — 复制任意内容开始"
                : "没有匹配的粘贴板内容"
        case .tag:
            emptyLabel.stringValue = searchField.stringValue.isEmpty
                ? "该分类暂无笔记"
                : "没有匹配的笔记"
        }
    }

    func updateFooter() {
        if let until = footerNoticeUntil, Date() < until {
            return // a notice is showing; it clears on the next interaction
        }
        footerNoticeUntil = nil
        let selectable = rows.filter { row in
            if case .header = row { return false }
            return true
        }
        // Total only — the selected ordinal carries no meaning.
        footerLeft.stringValue = "总共 \(selectable.count) 项"
        footerRight.stringValue = tab == .clipboard
            ? "⌘P 置顶 · ↩ 粘贴 · 双击粘贴"
            : "↩ 粘贴 · 双击粘贴"
    }

    func showFooterNotice(_ text: String) {
        footerNoticeUntil = Date().addingTimeInterval(2)
        footerLeft.stringValue = text
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 44 }
        switch rows[row] {
        case .header:
            return ClipboardHeaderCell.height
        case .clip(let item):
            return ClipCell.rowHeight(for: item)
        case .note(let note):
            // The session height is served by index (see renamingRow) —
            // never query the row's live view here.
            return row == renamingRow
                ? ClipCell.renameRowHeight(forNote: note)
                : ClipCell.rowHeight(forNote: note)
        }
    }



    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .header = rows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
        // A row click hands the first responder to the table; the search
        // field owns the keyboard (typing, arrows, Enter-to-paste) — give
        // it straight back so only the keyboard can trigger pasting.
        if panel.firstResponder === tableView {
            panel.makeFirstResponder(searchField.field)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            let cell = reuse(ClipboardHeaderCell.self, row: row)
            cell.configure(title: title, color: cardTheme.secondaryText)
            return cell
        case .clip(let item):
            let cell = reuse(ClipCell.self, row: row)
            cell.configure(
                item: item, theme: cardTheme,
                thumbnail: thumbnail(for: item),
                sourceIcon: ClipboardMonitor.shared.cachedIcon(forBundleID: item.sourceBundleID))
            return cell
        case .note(let note):
            let cell = reuse(ClipCell.self, row: row)
            cell.configureNote(
                note: note, theme: cardTheme,
                sourceIcon: Self.noteGlyph,
                iconTint: noteIconTint())
            return cell
        }
    }

    /// Note glyph: SF Symbol (template) — filled lucide shapes collapse
    /// into a color blob at row size. Tinted per category on the image
    /// view (contentTintColor), so recolors are instant with no baked
    /// bitmaps.
    static let noteGlyphSize: CGFloat = 17
    static let noteGlyph: NSImage? = NSImage(
        systemSymbolName: "note.text", accessibilityDescription: "note"
    )?.withSymbolConfiguration(
        .init(pointSize: 15, weight: .medium)
    )

    /// Note rows wear their category's color — same rule as the chip dots.
    private func noteIconTint() -> NSColor {
        guard case .tag(let name) = tab else { return .systemGray }
        return tagChipColor(named: name)
    }


    // MARK: row drag-reorder (notes tabs; native table drag & drop)

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard tab != .clipboard, rows.indices.contains(row),
              case .note(let note) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(note.id), forType: Self.noteDragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tab != .clipboard, draggingNoteID(info) != nil,
              row <= rows.count else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard tab != .clipboard, let id = draggingNoteID(info),
              let from = rows.firstIndex(where: { element in
                  if case .note(let n) = element { return n.id == id }
                  return false
              }) else { return false }
        var target = row
        if target > from { target -= 1 } // list shrinks by one before the slot
        guard target != from, rows.indices.contains(target) || target == rows.count else {
            return false
        }
        var ordered = notes
        if let noteFrom = ordered.firstIndex(where: { $0.id == id }) {
            let moved = ordered.remove(at: noteFrom)
            let noteTarget = min(target, ordered.count)
            ordered.insert(moved, at: noteTarget)
        }
        // Persist the tab's new order through the same channel every other
        // note mutation uses; the notes push re-renders the list.
        let category = noteCategory(of: id)
        let ids = ordered.filter { $0.category == category }.map(\.id)
        onAction?("note-reorder", ids.map(String.init).joined(separator: ","))
        return true
    }
    private func draggingNoteID(_ info: NSDraggingInfo) -> Int64? {
        let pb = info.draggingPasteboard
        guard let raw = pb.string(forType: Self.noteDragType) else { return nil }
        return Int64(raw)
    }

    private func noteCategory(of id: Int64) -> String? {
        notes.first { $0.id == id }?.category
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("LauncherRowView"),
            owner: self
        ) as? LauncherRowView ?? LauncherRowView()
        view.identifier = NSUserInterfaceItemIdentifier("LauncherRowView")
        // macOS's own selection color (accent-following, theme-dynamic) —
        // not a hand-mixed fill; the cells flip their text to white on it.
        view.fillColor = .selectedContentBackgroundColor
        view.hoverFillColor = cardTheme.hoverFill
        view.insetDx = PanelDesign.rowCapsuleInsetX
        view.insetDy = PanelDesign.rowCapsuleInsetY
        return view
    }

    private func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let cached = thumbnailCache.object(forKey: item.id.uuidString as NSString) { return cached }
        guard let store, let url = store.imageURL(for: item) else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        // No forced size: the image view scales proportionally inside its
        // square box — pre-setting a square logical size squished
        // non-square captures.
        if let image {
            thumbnailCache.setObject(image, forKey: item.id.uuidString as NSString)
        }
        return image
    }

    private func reuse<T: NSView>(_ type: T.Type, row: Int) -> T {
        let identifier = NSUserInterfaceItemIdentifier(String(describing: type))
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? T {
            return reused
        }
        let view = T(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 44))
        view.identifier = identifier
        return view
    }
}
