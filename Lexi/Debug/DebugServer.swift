import AppKit
import Foundation
import Network
import ScreenCaptureKit
// ---------------------------------------------------------------------------
// Debug display server: the toolbar TCP listener. Production triggers all
// live in-process now (ShortcutMonitor, SelectionPipeline, status item); the
// remaining routes exist for headless debugging only.
// ---------------------------------------------------------------------------

extension SelectionToolbarApp {
    // MARK: - HTTP request routing (helper's display server)

    func handleRequestData(_ data: Data) {
        let request = String(data: data, encoding: .utf8) ?? ""



        if request.hasPrefix("POST /debug-taginput-esc ") {
            DispatchQueue.main.async {
                self.debugTagInputEscE2E()
            }
            return
        }

        if request.hasPrefix("POST /debug-rename-e2e ") {
            // End-to-end rename repro on a sacrificial REAL note: seeds a
            // row, opens the rename editor, types into the live field
            // editor, sends a real Return through NSApp (never the HID
            // tap — the user's frontmost app must not receive keys), then
            // reports the DB name after commit and after a category move.
            DispatchQueue.main.async {
                self.debugRenameE2E()
            }
            return
        }

        if request.hasPrefix("POST /debug-clip-shot") {
            let wantsNotes = request.contains("?tab=notes")
            let renameRow: Int? = request.contains("&rename=")
                ? Int(request.components(separatedBy: "&rename=").last?
                    .components(separatedBy: " ")[0]
                    .components(separatedBy: "&").first ?? "")
                : nil
            let plusProbe = request.contains("&plus=1")
            let tagColor: String? = request.contains("&tagcolor=")
                ? request.components(separatedBy: "&tagcolor=").last?
                    .components(separatedBy: " ")[0]
                    .components(separatedBy: "&").first
                    .flatMap { $0.isEmpty ? nil : $0.removingPercentEncoding ?? $0 }
                : nil
            let tagRenameTarget: String? = request.contains("&tagrename=")
                ? request.components(separatedBy: "&tagrename=").last?
                    .components(separatedBy: " ")[0]
                    .components(separatedBy: "&").first
                    .flatMap { $0.isEmpty ? nil : $0.removingPercentEncoding ?? $0 }
                : nil
            DispatchQueue.main.async {
                self.debugClipboardShot(
                    notes: wantsNotes, renameRow: renameRow, plusProbe: plusProbe,
                    tagRenameTarget: tagRenameTarget, tagColor: tagColor)
            }
            return
        }

        if request.hasPrefix("POST /debug-colormenu-shot") {
            let tag = request.components(separatedBy: "&tag=").last?
                .components(separatedBy: " ")[0]
                .components(separatedBy: "&").first
                .flatMap { $0.isEmpty ? nil : $0.removingPercentEncoding ?? $0 }
                ?? "工作"
            DispatchQueue.main.async {
                self.debugColorMenuShot(tag: tag)
            }
            return
        }


        if request.hasPrefix("POST /debug-launcher-shot") {
            // Shows the launcher, settles, snapshots to /tmp — the folder
            // grid (?select=row,chip pre-selects a chip for keyboard-
            // selection repros), or with ?query= the unified results
            // list (calculator + folders + apps; URL-encoded, e.g.
            // ?query=1%2B1).
            // `query=` must actually be present — without the guard the
            // method ("POST") would parse as the query.
            let query: String? = request.contains("query=")
                ? request.components(separatedBy: "query=").last?
                    .components(separatedBy: " ")[0]
                    .components(separatedBy: "&").first?
                    .removingPercentEncoding
                    .flatMap { $0.isEmpty ? nil : $0 }
                : nil
            let compose = request.contains("&compose=1") || request.contains("compose=1")
            let select: (Int, Int)? = request
                .components(separatedBy: "select=").last?
                .components(separatedBy: " ")[0]
                .split(separator: ",")
                .compactMap { Int($0) }.count == 2
                ? {
                    let parts = request.components(separatedBy: "select=").last?
                        .components(separatedBy: " ")[0].split(separator: ",")
                        .compactMap { Int($0) } ?? []
                    return (parts[0], parts[1])
                }()
                : nil
            DispatchQueue.main.async {
                self.debugLauncherShot(query: query, compose: compose, select: select)
            }
            return
        }
        if request.hasPrefix("POST /debug-card-open") {
            // Reopen-state + resize-layout probe: opens the card via the
            // real showPopupCard path and LEAVES it open. `?resize=WxH`
            // applies a user resize (same clamp as the drag zones) so the
            // layout pass can be checked without synthetic mouse events.
            let spec = request.components(separatedBy: "?resize=").last?
                .components(separatedBy: " ")[0].split(separator: "x")
                .compactMap { Int($0) }
            DispatchQueue.main.async {
                self.showPopupCard()
                if spec?.count == 2, let w = spec?[0], let h = spec?[1] {
                    self.cardUserWidth = CGFloat(min(max(w, 360), 760))
                    self.cardUserHeight = CGFloat(min(max(h, 240), 900))
                    self.layoutResultCard()
                }
                FileLog.write("CARD-OPEN state panel=\(self.activePanel)")
            }
            return
        }
        if request.hasPrefix("POST /debug-card-shot") {
            if request.contains("?tab=notes") {
                let tagColor = request.components(separatedBy: "&tagcolor=").last?
                    .components(separatedBy: " ")[0]
                    .components(separatedBy: "&").first
                    .flatMap { $0.isEmpty ? nil : $0.removingPercentEncoding ?? $0 }
                DispatchQueue.main.async {
                    self.debugCardNotesShot(tagColor: tagColor)
                }
                return
            }
            DispatchQueue.main.async {
                self.debugCardReviewShot()
            }
            return
        }
        if request.hasPrefix("POST /debug-toolbar-shot ") {
            // Shows the selection toolbar with a sample payload — no host
            // app or real selection needed — then snapshots and hides.
            DispatchQueue.main.async {
                self.debugToolbarShot()
            }
            return
        }
        if request.hasPrefix("POST /debug-shot") {
            // /debug-shot?tab=vocabulary — navigate, settle, snapshot to /tmp.
            let tabName = request
                .components(separatedBy: " ")[1]
                .components(separatedBy: "?tab=").last?
                .components(separatedBy: " ").first?
                .components(separatedBy: "&").first ?? "general"
            let tab = SettingsTab.allCases.first { $0.name == tabName } ?? .general
            let wantsReveal = request.contains("&reveal=1")
            DispatchQueue.main.async {
                if wantsReveal {
                    ReviewPane.debugRevealNext = true
                    // Navigate away first: an open window reuses the pane,
                    // so the seeded init only runs when review remounts.
                    self.showSettingsWindow(tab: .general)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (wantsReveal ? 0.3 : 0)) {
                    self.showSettingsWindow(tab: tab)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        MainActor.assumeIsolated {
                            guard let png = self.settingsWindowController?.snapshotPNG() else {
                                FileLog.write("SHOT fail: no window")
                                return
                            }
                            let path = "/tmp/lexi-settings-\(tab.name).png"
                            try? png.write(to: URL(fileURLWithPath: path))
                            FileLog.write("SHOT saved path=\(path) bytes=\(png.count)")
                        }
                    }
                }
            }
            return
        }
        if request.hasPrefix("GET /debug-state ") || request.hasPrefix("POST /debug-state ") {
            DispatchQueue.main.async {
                let runs = self.cardRuns.map { "\($0.id)|\($0.status)|len=\($0.text.count)" }.joined(separator: "; ")
                let notesVis = NSStringFromRect(self.cardNotesClip.contentView.visibleRect)
                let notesDoc = NSStringFromRect(self.cardNotesClip.documentView?.frame ?? .zero)

                let state = "notesSel=\(self.notesTableView?.selectedRow ?? -99) notesCount=\(self.cardNotesItems.count) notesVis=\(notesVis) notesDoc=\(notesDoc) runsBar=\(NSStringFromRect(self.resultRunsBar.frame)) tabsClip=\(NSStringFromRect(self.resultTabsClip.frame)) doc=\(NSStringFromRect(self.resultTabsClip.documentView?.frame ?? .zero)) trash=\(NSStringFromRect(self.resultTrashButton.frame)) chips=\(self.runChipViews.count) activeRunId=\(self.activeRunId ?? "-") panel=\(self.activePanel) pinned=\(self.cardPinned) runs=[\(runs)] tvLen=\(self.resultTextView.textStorage?.length ?? 0) scrollHidden=\(self.resultScrollView.isHidden) scroll=\(NSStringFromRect(self.resultScrollView.frame)) tv=\(NSStringFromRect(self.resultTextView.frame)) container=\(NSStringFromRect(self.resultContainer.frame)) panelFrame=\(NSStringFromRect(self.resultPanel.frame)) input=\(NSStringFromRect(self.inputContainer.frame)) tvInset=\(self.inputTextView.textContainerInset) tvFrame=\(self.inputTextView.frame) actions=\(self.cardActions.count)"
                self.log("STATE \(state)")
                self.log("DEBUG \(state)")
            }
            return
        }
    }

    /// Headless toolbar snapshot for the /debug-toolbar-shot route: shows
    /// the REAL panel with a sample selection payload (the AX pipeline is
    /// bypassed — no host app or screen real estate needed), settles,
    /// captures, hides.
    func debugToolbarShot() {
        MainActor.assumeIsolated {
            refreshCardActions()
            showPanel(ShowPayload(
                text: "The quick brown fox jumps over the lazy dog.",
                x: 660, y: 500
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let png = self.panel.contentView?.snapshotPNG() {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/lexi-toolbar.png"))
                    FileLog.write("TOOLBAR-SHOT saved bytes=\(png.count)")
                }
                self.hidePanel()
            }
        }
    }


    /// Pops the REAL chip color submenu on screen, captures it via
    /// ScreenCaptureKit (menus render in WindowServer, not in-process),
    /// then dismisses with a synthesized Esc. Ground truth for swatches.
    func debugColorMenuShot(tag: String) {
        MainActor.assumeIsolated {
            let menu = clipboardController.debugColorMenu(for: tag)
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 200, y: 200, width: 1000, height: 600)
            let point = NSPoint(x: screen.midX, y: screen.midY + 60)
            let screenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            DispatchQueue.global(qos: .userInitiated).async {
                Thread.sleep(forTimeInterval: 0.8)
                if let cg = Self.captureScreenSync(preferred: screenID) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/lexi-colormenu.png"))
                        FileLog.write("COLORMENU saved bytes=\(png.count)")
                    }
                }
                if let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true) {
                    esc.post(tap: .cghidEventTap)
                }
            }
            menu.popUp(positioning: nil, at: point, in: nil)
            FileLog.write("COLORMENU dismissed")
        }
    }

    /// ScreenCaptureKit capture, synchronously bridged (menus live in the
    /// WindowServer; only a screen capture sees them).
    private static func captureScreenSync(preferred: CGDirectDisplayID?) -> CGImage? {
        let sem = DispatchSemaphore(value: 0)
        var out: CGImage?
        Task {
            let config = SCStreamConfiguration()
            config.showsCursor = false
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
                let display = content.displays.first { $0.displayID == preferred }
                    ?? content.displays.first
                if let display,
                   let cg = try? await SCScreenshotManager.captureImage(
                       contentFilter: SCContentFilter(display: display, excludingWindows: []),
                       configuration: config) {
                    out = cg
                }
            }
            sem.signal()
        }
        sem.wait()
        return out
    }

    // MARK: - clipboard panel layout probe (/debug-clip-shot)

    /// Seeds deterministic layout probes (marker-tagged so cleanup is
    /// exact), snapshots the clipboard panel to /tmp/lexi-clipboard.png,
    /// then removes them. `notes: true` swaps in a synthetic notes tab;
    /// `plusProbe` seeds a full chip row and opens the ＋ input;
    /// `tagRenameTarget` folds that tag's chip into the rename input;
    /// `tagColor` ("name|#RRGGBB") drives the REAL color-pick action chain.
    func debugClipboardShot(notes wantsNotes: Bool = false, renameRow: Int? = nil, plusProbe: Bool = false, tagRenameTarget: String? = nil, tagColor: String? = nil) {
        MainActor.assumeIsolated {
            guard let store = clipboardStore else {
                FileLog.write("CLIP-SHOT fail: no store")
                return
            }
            var seeded: [ClipboardItem] = []
            if !wantsNotes {
                let marker = "▲probe"
                let source = "com.apple.Safari"
                if let png = Self.probeImage(), let item = store.addImage(png, sourceBundleID: source) {
                    seeded.append(item)
                }
                store.addFiles(["/tmp/\(marker)/季度报告 Q4 final.pdf"], sourceBundleID: source)
                if let fileRow = store.items.first, fileRow.kind == .file {
                    seeded.append(fileRow)
                }
                let texts = [
                    "\(marker) short 单行文本 single line",
                    "\(marker) " + String(repeating: "两行文本 ", count: 10),
                    "\(marker) " + String(repeating: "五行文本测试 ", count: 20),
                    "\(marker) overflow " + String(repeating: "超长文本 ", count: 40),
                ]
                for text in texts {
                    store.addText(text, sourceBundleID: source)
                    if let first = store.items.first, first.text == text {
                        seeded.append(first)
                    }
                }
                clipboardController.show()
            } else {
                let notes = [
                    ClipboardNote(
                        id: 1, name: "会议纪要",
                        content: String(repeating: "讨论项目排期与资源分配 ", count: 14),
                        category: "工作"),
                    ClipboardNote(
                        id: 2, name: "",
                        content: String(repeating: "未命名笔记的多行内容测试 ", count: 18),
                        category: "工作"),
                ]
                clipboardController.debugShowNotes(
                    notes: notes, categories: ["工作", "学习英语"], tag: "工作")
            }

            var plusProbe = plusProbe

            func snapshot(_ name: String) {
                guard let png = clipboardController.snapshotPNG() else {
                    FileLog.write("CLIP-SHOT fail: no window")
                    return
                }
                let path = "/tmp/lexi-clipboard.png"
                try? png.write(to: URL(fileURLWithPath: path))
                FileLog.write("CLIP-SHOT \(name) path=\(path) bytes=\(png.count)")
            }
            func cleanup() {
                clipboardController.hide(notify: false)
                for item in seeded { store.delete(item) }
                if wantsNotes {
                    // Restore the real notes snapshot (pushed on next
                    // real open anyway) so no synthetic chip lingers.
                    clipboardController.updateNotes(notes: [], categories: [])
                }
            }

            let wantsScreen = plusProbe == false && tagColor == nil
                && tagRenameTarget == nil && renameRow == nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    snapshot("base")
                    if wantsScreen {
                        // Full-screen capture: the window-server blur shows
                        // only with real content behind the panel.
                        let displayID = self.clipboardController.panel.screen?
                            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                        Task {
                            // Every display: the panel follows the cursor,
                            // which may not be the capture's first screen.
                            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                                false, onScreenWindowsOnly: false) else {
                                FileLog.write("SCREEN-SHOT shareable-content failed")
                                return
                            }
                            let config = SCStreamConfiguration()
                            config.showsCursor = false
                            for (index, display) in content.displays.enumerated() {
                                guard let cg = try? await SCScreenshotManager.captureImage(
                                    contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                    configuration: config) else { continue }
                                let rep = NSBitmapImageRep(cgImage: cg)
                                if let png = rep.representation(using: .png, properties: [:]) {
                                    try? png.write(to: URL(fileURLWithPath: "/tmp/lexi-screen-\(index).png"))
                                    FileLog.write("SCREEN-SHOT[\(index)] saved bytes=\(png.count)")
                                }
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            MainActor.assumeIsolated { cleanup() }
                        }
                        return
                    }
                    if plusProbe {
                        let many = (1...10).map { "分类\($0)号" }
                        self.clipboardController.debugShowNotes(
                            notes: [], categories: many, tag: many[0])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                self.clipboardController.debugBeginTagCreation()
                                self.clipboardController.tagInputView.stringValue = "新分类名"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    MainActor.assumeIsolated {
                                        snapshot("plus")
                                        self.clipboardController.debugLogChipsGeometry()
                                        cleanup()
                                    }
                                }
                            }
                        }
                    } else if let tagColor {
                        // Real production chain: the exact route the chip's
                        // color submenu fires. Scrolls the chip row fully
                        // right first — the rebuild must keep that place.
                        let name = String(tagColor.split(separator: "|").first ?? "")
                        let original = LexiStore.noteCategoryColor(named: name) ?? ""
                        // Widen the row first (synthetic chips) so there is
                        // somewhere to scroll to, then park fully right.
                        let many = (1...10).map { "分类\($0)号" }
                        self.clipboardController.debugShowNotes(
                            notes: [], categories: many, tag: many[0])
                        self.clipboardController.chipsContent.layoutSubtreeIfNeeded()
                        let clip = self.clipboardController.chipsScrollView.contentView
                        let doc = self.clipboardController.chipsContent
                        let farX = max(0, doc.frame.width - clip.bounds.width)
                        clip.scroll(to: NSPoint(x: farX, y: 0))
                        self.clipboardController.chipsScrollView.reflectScrolledClipView(clip)
                        FileLog.write("COLORMENU before farX=\(farX) visible=\(NSStringFromRect(clip.documentVisibleRect))")
                        self.handleAction(action: "note-tag-color", text: tagColor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                snapshot("tagcolor")
                                self.clipboardController.debugLogChipsGeometry()
                                LexiStore.setNoteCategoryColor(named: name, hex: original)
                                self.reloadCardNotes()
                                cleanup()
                            }
                        }
                    } else if let tag = tagRenameTarget {
                        self.clipboardController.debugBeginTagRename(tag)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                snapshot("tagrename")
                                cleanup()
                            }
                        }
                    } else if let row = renameRow {
                        self.clipboardController.debugBeginRename(row: row)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                snapshot("rename")
                                cleanup()
                            }
                        }
                    } else {
                        cleanup()
                    }
                }
            }
        }
    }

    /// Shows the launcher (folder grid, or ?query= for the unified
    /// results list — `compose=1` leaves the query in the IME-composition
    /// state) and snapshots it. ?select=row,chip pre-selects a folder
    /// chip (keyboard-selection repro).
    func debugLauncherShot(query: String? = nil, compose: Bool = false, select: (Int, Int)? = nil) {
        MainActor.assumeIsolated {
            launcherController.show()
            if let query {
                launcherController.debugSetQuery(query, compose: compose)
            } else if let (row, chip) = select {
                launcherController.debugSelectChip(row: row, chip: chip)
            }
            // Search-mode shots wait for the debounced Spotlight fetch
            // (~1.2s) to land; grid shots need only layout.
            let settle: TimeInterval = query != nil ? 2.5 : 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                MainActor.assumeIsolated {
                    // Exact layout telemetry — header/chip rhythm ground truth.
                    self.launcherController.logRowGeometry()
                    if let png = self.launcherController.snapshotPNG() {
                        let path = "/tmp/lexi-launcher.png"
                        try? png.write(to: URL(fileURLWithPath: path))
                        FileLog.write("LAUNCH-SHOT saved path=\(path) bytes=\(png.count)")
                    } else {
                        FileLog.write("LAUNCH-SHOT fail: no window")
                    }
                    self.launcherController.hide(notify: false)
                }
            }
        }
    }


    /// Review-tab md-rendering probe: open card → review tab → next word →
    /// reveal → snapshot. Also exercises the restyled top tab pills.
    func debugCardReviewShot() {
        MainActor.assumeIsolated {
            showPopupCard()
            showPanelTab("review")
            loadReviewWord()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    self.debugRevealReview()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated {
                            guard let content = self.resultPanel.contentView else {
                                FileLog.write("CARD-SHOT fail: no window")
                                return
                            }
                            if let png = content.snapshotPNG() {
                                let path = "/tmp/lexi-card.png"
                                try? png.write(to: URL(fileURLWithPath: path))
                                FileLog.write("CARD-SHOT saved path=\(path) bytes=\(png.count)")
                            }
                            self.resultPanel.orderOut(nil)
                        }
                    }
                }
            }
        }
    }

    /// Notes-tab probe: open card → notes tab (real DB feed) → snapshot.
    /// `tagColor` ("name|#RRGGBB") fires the REAL color action against the
    /// ALREADY-OPEN card and snapshots again — the live-refresh check.
    /// Restores the original color afterwards.
    func debugCardNotesShot(tagColor: String? = nil) {
        MainActor.assumeIsolated {
            showPopupCard()
            showPanelTab("notes")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    self.snapshotCardNotes("open")
                    guard let tagColor else {
                        self.resultPanel.orderOut(nil)
                        return
                    }
                    let name = String(tagColor.split(separator: "|").first ?? "")
                    let original = LexiStore.noteCategoryColor(named: name) ?? ""
                    self.handleAction(action: "note-tag-color", text: tagColor)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        MainActor.assumeIsolated {
                            self.snapshotCardNotes("live-color")
                            LexiStore.setNoteCategoryColor(named: name, hex: original)
                            self.reloadCardNotes()
                            self.resultPanel.orderOut(nil)
                        }
                    }
                }
            }
        }
    }

    private func snapshotCardNotes(_ name: String) {
        guard let content = resultPanel.contentView else {
            FileLog.write("CARD-NOTES-SHOT fail: no window")
            return
        }
        if let png = content.snapshotPNG() {
            let path = "/tmp/lexi-card-notes-\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))
            FileLog.write("CARD-NOTES-SHOT \(name) path=\(path) bytes=\(png.count)")
        }
    }

    /// End-to-end rename repro on a sacrificial real note (the reported
    /// bug: rename in Tmp → move to a category → name gone). Drives the
    /// exact UI path: menu rename → typed field editor → real Return →
    /// onAction → handleAction → DB → push. Reports the DB name at each
    /// step; the note is deleted afterwards.
    func debugRenameE2E() {
        MainActor.assumeIsolated {
            let marker = "▲rename-e2e \(Int(Date().timeIntervalSince1970))"
            LexiStore.insertNote(content: marker)
            guard let note = LexiStore.notes(limit: 50).first(where: { $0.content == marker }) else {
                FileLog.write("E2E fail: sacrificial note not created")
                return
            }
            let noteId = note.id
            func dbName(_ stage: String) {
                let row = LexiStore.notes(limit: 50).first { $0.id == noteId }
                FileLog.write("E2E \(stage) id=\(noteId) name=\(row?.name ?? "<nil>") cat=\(row?.categoryName ?? "<nil>")")
            }
            dbName("created")

            clipboardController.debugShowNotes(
                notes: [ClipboardNote(id: noteId, name: "", content: marker, category: nil)],
                categories: [], tag: "Note")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    self.clipboardController.debugBeginRename(row: 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated {
                            FileLog.write("E2E responder-after-open=\(String(describing: self.clipboardController.panelFirstResponder()))")
                            guard let editor = self.clipboardController.panelFirstResponder() as? NSTextView else {
                                FileLog.write("E2E fail: no field editor")
                                LexiStore.deleteNote(id: noteId)
                                return
                            }
                            editor.insertText("端到端名字")
                            // Real Return key into OUR app only.
                            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true),
                               let nsDown = NSEvent(cgEvent: down) {
                                NSApp.sendEvent(nsDown)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                MainActor.assumeIsolated {
                                    self.dbNameSafe(noteId, "after-commit")
                                    // The move path next: same handler the menu uses.
                                    self.handleAction(action: "note-tag", text: "\(noteId)|Note")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        MainActor.assumeIsolated {
                                            self.dbNameSafe(noteId, "after-move")
                                            LexiStore.deleteNote(id: noteId)
                                            self.clipboardController.hide(notify: false)
                                            self.clipboardController.updateNotes(notes: [], categories: [])
                                            FileLog.write("E2E done (note deleted)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func dbNameSafe(_ noteId: Int64, _ stage: String) {
        let row = LexiStore.notes(limit: 50).first { $0.id == noteId }
        FileLog.write("E2E \(stage) id=\(noteId) name=\(row?.name ?? "<nil>") cat=\(row?.categoryName ?? "<nil>")")
    }

    /// ＋ input ESC repro: open the tag input, log the responder, send a
    /// REAL Esc key, report whether the input folded back.
    func debugTagInputEscE2E() {
        MainActor.assumeIsolated {
            clipboardController.debugShowNotes(
                notes: [], categories: ["工作"], tag: "工作")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    self.clipboardController.beginTagCreation()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated {
                            let responder = self.clipboardController.panelFirstResponder()
                            FileLog.write("TAGESC responder=\(String(describing: type(of: responder))) keyWindow=\(String(describing: NSApp.keyWindow)) panelKey=\(self.clipboardController.panel.isKeyWindow)")
                            // Real Esc into our app only.
                            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true),
                               let nsDown = NSEvent(cgEvent: down) {
                                NSApp.sendEvent(nsDown)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                MainActor.assumeIsolated {
                                    func report(_ stage: String) {
                                        let inputVisible = !self.clipboardController.tagInputView.isHidden
                                        let arranged = self.clipboardController.chipsContent.arrangedSubviews
                                            .contains(self.clipboardController.tagInputView)
                                        FileLog.write("TAGESC \(stage) inputVisible=\(inputVisible) arranged=\(arranged)")
                                    }
                                    report("after-esc")
                                    // Retry with the panel definitively key.
                                    self.clipboardController.panel.makeKey()
                                    if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true),
                                       let nsDown = NSEvent(cgEvent: down) {
                                        NSApp.sendEvent(nsDown)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                        MainActor.assumeIsolated {
                                            report("after-key-esc")
                                            self.clipboardController.hide(notify: false)
                                            self.clipboardController.updateNotes(notes: [], categories: [])
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func probeImage() -> Data? {
        let size = NSSize(width: 120, height: 90)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [.systemBlue, .systemTeal])?.draw(
            in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func writeResponse(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
