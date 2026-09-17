import Foundation
import Network

// ---------------------------------------------------------------------------
// Debug display server: the toolbar TCP listener. Production triggers all
// live in-process now (ShortcutMonitor, SelectionPipeline, status item); the
// remaining routes exist for headless debugging only.
// ---------------------------------------------------------------------------

extension SelectionToolbarApp {
    // MARK: - HTTP request routing (helper's display server)

    func handleRequestData(_ data: Data) {
        let request = String(data: data, encoding: .utf8) ?? ""



        if request.hasPrefix("POST /debug-paste-test ") {
            DispatchQueue.main.async {
                FileLog.write("PASTE test: route-driven pasteSelected")
                self.clipboardController.debugPasteSelected()
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
            DispatchQueue.main.async {
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

    func writeResponse(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
