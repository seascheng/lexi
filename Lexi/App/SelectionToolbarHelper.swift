import AppKit
import Foundation
import Network

final class SelectionToolbarApp: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var container: NSView!
    var dragHandle: ToolbarDragHandle!
    var buttons: [ToolbarButton] = []
    var actions = defaultToolbarActions()
    var theme: ToolbarTheme = .dark
    var cardTheme: CardTheme { theme == .dark ? CardTheme.dark : CardTheme.light }
    var selectedText = ""
    var localKeyMonitor: Any?
    var globalKeyMonitor: Any?
    var localMouseMonitor: Any?
    var globalMouseMonitor: Any?
    var localMouseMoveMonitor: Any?
    var globalMouseMoveMonitor: Any?
    var globalScrollMonitor: Any?
    lazy var launcherController: LauncherPanelController = {
        let controller = LauncherPanelController()
        controller.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        return controller
    }()

    lazy var clipboardController: ClipboardPanelController = {
        let controller = ClipboardPanelController()
        controller.onAction = { [weak self] action, text in
            self?.handleAction(action: action, text: text)
        }
        return controller
    }()
    /// The clipboard history store (nil when the DB could not be opened —
    /// capture is disabled then). Kept for debug routes that seed probes.
    var clipboardStore: ClipboardStore?
    var panelTabPills: [NSButton] = []
    var cardCategories: [String] = []
    var resultPanel: KeyablePanel!
    var resultContainer: NSView!
    var resultTabsView: NSView!
    var resultTabsClip: HorizontalOnlyClip!
    var resultTrashButton: NSButton!
    var resultCloseButton: NSButton!
    var resultScrollView: NSScrollView!
    var resultTextView: NSTextView!
    var resultLoadingIndicator: NSProgressIndicator!
    var resultLoadingLabel: NSTextField!
    var translateIdleView: NSView!
    var resultIdleLabel: NSTextField!
    var resultIdleHint: NSTextField!
    var resultIdleIcon: NSImageView!
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var resultActionBar: NSView!
    var entryPicker: NSSegmentedControl!
    var resultCopyButton: NSButton!
    var resultSaveButton: NSButton!
    var inputContainer: NSView!
    var inputTextView: CardInputTextView!
    var runsSeparator: NSView!
    var inputButtonsRow: NSView!
    var inputButtonsClip: HorizontalOnlyClip!
    var cardRuns: [CardRun] = []
    var cardActions: [CardActionsPayload.Item] = []
    var activeRunId: String?
    var activePanel = "translate"

    /// In-flight AI stream tasks per run id — cancelled when their runs go.
    var cardRunTasks: [String: Task<Void, Never>] = [:]
    var panelDefs: [(id: String, name: String, icon: String)] = []
    var cardPanelTabsView: NSView!
    var resultRunsBar: NSView!
    var cardNotesClip: HorizontalOnlyClip!

    var notesTableView: NotesTable!
    var noteSearchContainer: NSView!
    var noteSearchField: CardInputTextField!
    var noteTagBar: NSView!
    var noteTagPicker: NSSegmentedControl?
    var noteSearchText = ""
    var noteActiveCategory = "all"
    var displayedNotes: [CardNotesPayload.Note] = []
    var cardNotesItems: [CardNotesPayload.Note] = []
    /// Stored category colors (name → hex), refreshed with the notes feed.
    var cardTagHexColors: [String: String] = [:]
    var reviewCardView: NSView!
    var reviewWordLabel: NSTextField!
    var reviewAnswerLabel: NSTextField!
    var cardPinned = false
    /// The app that was frontmost when the card/toolbar opened — the target
    /// for note-insert's paste-at-caret and handoff-style flows.
    var sourceApp: NSRunningApplication?
    var reviewRevealButton: NSButton!
    var reviewGradeButtons: [NSButton] = []
    var reviewEmptyLabel: NSTextField!
    var reviewCurrentWordId: Int64 = 0
    /// Arrow-key navigation: popped cards for ←, and the skip flag so a
    /// back step doesn't push the card it just re-showed.
    var reviewBackLog: [CardReviewPayload] = []
    var reviewSkipPush = false
    /// answer label on reveal (raw text used to show literal ** asterisks).
    var reviewAnswerMarkdown: String = ""
    var runChipViews: [RunChipView] = []
    var runTabsContentWidth: CGFloat = 376
    // Card opens at the user's preferred size (drag-resizable; double-click
    // a resize zone still returns to the auto-size default).
    var cardUserWidth: CGFloat? = 428
    var cardUserHeight: CGFloat? = 400
    var resizeCorner: CardResizeZone!
    var resizeRight: CardResizeZone!
    var resizeBottom: CardResizeZone!
    var listener: NWListener?
    let listenerQueue = DispatchQueue(label: "lexi.toolbar.display")
    /// Native settings window (full-Swift migration, phase 1). Created on
    /// first show; the app controller itself is nonisolated, so every touch
    /// hops through `MainActor.assumeIsolated` on the main queue.
    var settingsWindowController: LexiSettingsWindowController?
    let toolbarPort: UInt16

    override init() {
        toolbarPort = UInt16(SelectionToolbarApp.argumentValue("--toolbar-port") ?? "") ?? 43877
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = LexiLogo.appIcon
        log("helper started bundle=\(Bundle.main.bundleIdentifier ?? "none") toolbarPort=\(toolbarPort)")
        LexiStore.ensureSchema()
        AppUsage.shared.start()
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        terminateOlderHelperInstances()
        buildPanel()
        buildResultCard()
        installMouseMonitors()
        installStatusItem()
        // Persisted panel style — previously pushed by the Rust /theme route,
        // which died with it. Must run AFTER the views exist: applyTheme
        // relayouts the card. Applies to toolbar, card, launcher, clipboard.
        PanelStyle.update(
            opacity: CGFloat(LexiStore.settingInt("panelOpacity", in: 10...90, default: 40)) / 100.0,
            blur: LexiStore.setting("panelBlur").flatMap(PanelStyle.Blur.init(rawValue:))
        )
        applyTheme(LexiStore.setting("theme") ?? "dark")
        refreshCardActions()
        startDisplayServer()
        shortcutMonitor = ShortcutMonitor(
            onLauncher: { [weak self] in
                self?.launcherController.show()
            },
            onClipboard: { [weak self] in self?.showClipboardPanel() },
            onPopup: { [weak self] in self?.showPopupCard() }
        )
        shortcutMonitor?.onCopyCommand = { [weak self] in
            self?.selectionPipeline?.noteCopyCommand()
        }
        // Clipboard capture: own store + 0.5s poller.
        if let store = ClipboardStore.open() {
            clipboardStore = store
            clipboardController.attach(store: store)
            ClipboardMonitor.shared.start(store: store)
        } else {
            FileLog.write("CLIP store unavailable — capture disabled")
        }
        selectionPipeline = SelectionPipeline()
        selectionPipeline?.onSelection = { [weak self] text, point in
            self?.showToolbarFromSwift(text: text, at: point)
        }
        selectionPipeline?.ownFrames = {
            NSApp.windows.filter { $0.isVisible }.map(\.frame)
        }
        selectionPipeline?.start()
    }

    /// Space-switch observer: registered once in installMouseMonitors;
    /// app-lifetime, like the event monitors beside it.
    var spaceChangeObserver: NSObjectProtocol?

    /// Global keyboard shortcuts (launcher + clipboard), in-process.
    var shortcutMonitor: ShortcutMonitor?
    var selectionPipeline: SelectionPipeline?
    var lastToolbarShow: (text: String, at: Date)?

    /// Dedup gate: identical selection text within 600ms shows once
    /// (selection drag and Cmd+C fallback can both fire for one gesture).
    func selectionShowGate(_ rawText: String) -> Bool {
        let key = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        if let last = lastToolbarShow, last.text == key, now.timeIntervalSince(last.at) < 0.6 {
            return false
        }
        lastToolbarShow = (key, now)
        return true
    }


    private static func argumentValue(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }


    /// Layer-1 selection trigger from the helper's own tap.
    func showToolbarFromSwift(text: String, at point: NSPoint) {
        // NO gate here — showPanel has the only gate (dedup between the
        // tap trigger and the Cmd+C fallback, which can both fire for one
        // selection gesture). Gating in both places makes the second call
        // self-reject.
        showPanel(ShowPayload(text: text, x: Int(point.x), y: Int(point.y)))
    }

    /// The popup shortcut's action: open the idle card (Actions tab, no
    /// run yet) with the current selection pre-filled if available.
    /// Replaces Rust's trigger_popup_with_selection.
    func showPopupCard() {
        // The action bar must reflect the current enable/order config at
        // popup time, not whatever snapshot the last refresh left.
        refreshCardActions()
        // Try to read the current selection; empty = idle card with no input.
        let selection = SelectionPipeline.readSelectedText()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showResultCard(ResultShowPayload(inputText: selection))
    }

    func terminateOlderHelperInstances() {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let currentBundleId = Bundle.main.bundleIdentifier

        for application in NSWorkspace.shared.runningApplications {
            guard application.bundleIdentifier == currentBundleId,
                  application.processIdentifier != currentPid else {
                continue
            }

            log("terminating stale helper pid=\(application.processIdentifier)")
            application.terminate()
        }
    }


    var statusItem: NSStatusItem?

    /// Menu-bar presence: the native successor to the tauri tray.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = LexiLogo.menuBarImage
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(statusSettingsClicked), keyEquivalent: ",")
        let launcherItem = NSMenuItem(title: "Open Launcher", action: #selector(statusLauncherClicked), keyEquivalent: "l")
        let quitItem = NSMenuItem(title: "Quit Lexi", action: #selector(statusQuitClicked), keyEquivalent: "q")
        for entry in [settingsItem, launcherItem, quitItem] { entry.target = self }
        menu.addItem(settingsItem)
        menu.addItem(launcherItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc func statusSettingsClicked() {
        showSettingsWindow()
    }

    @objc func statusLauncherClicked() {
        launcherController.show()
    }

    @objc func statusQuitClicked() {
        NSApp.terminate(nil)
    }
    func escapeResultCardIfNeeded() {
        guard resultPanel?.isVisible == true, !cardPinned else { return }
        resultPanel.orderOut(nil)
        clearAllRuns()
    }

    /// Dismissal radius: scales with the screen width (180–280pt). Computed
    /// ONCE per show — the mouseMoved monitors fire on every system mouse
    /// event and must not scan NSScreen.screens each time.
    func dismissalRadius(for location: NSPoint) -> CGFloat {
        let screenWidth = (NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main)?
            .frame.width ?? 1440
        return max(180, min(screenWidth * 0.12, 280))
    }

    /// Cached at showPanel time; 0 until the first show.
    var cachedDismissalRadius: CGFloat = 0


    var isInputFocused = false


    func log(_ message: String) {
        FileLog.write(message)
    }


    /// Dev-only headless debugging server (the /debug-* routes in
    /// DebugServer.swift — see AGENTS.md). Disabled unless launched with
    /// --debug-server, and loopback-bound when enabled: the routes can
    /// drive the UI and synthesize pastes, so they must never be
    /// reachable from the network.
    func startDisplayServer() {
        guard CommandLine.arguments.contains("--debug-server") else { return }
        guard let port = NWEndpoint.Port(rawValue: toolbarPort) else {
            log("invalid toolbar port \(toolbarPort)")
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            log("toolbar listener failed \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.log("toolbar listener state \(state)")
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        listener?.start(queue: listenerQueue)
        log("toolbar listener start requested (loopback:\(port))")
    }

    func receive(_ connection: NWConnection, accumulated: Data = Data()) {
        // Connections from NWListener must be started explicitly.
        connection.start(queue: listenerQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if buffer.isEmpty || error != nil {
                self.writeResponse(connection)
                return
            }
            // A receive() may return half a TCP segment. Wait until the full
            // header + Content-Length body has arrived — processing a truncated
            // request corrupts multi-byte UTF-8 (the reported \u{FFFD} mojibake)
            // and silently drops large streamed payloads.
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.receive(connection, accumulated: buffer)
                return
            }
            let header = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
            let declaredLength = header.lowercased()
                .split(separator: "\r\n")
                .first(where: { $0.contains("content-length") })
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            if buffer.count - headerRange.upperBound >= declaredLength {
                self.handleRequestData(buffer)
                self.writeResponse(connection)
            } else {
                self.receive(connection, accumulated: buffer)
            }
        }
    }


    func toolbarWidth(for actionCount: Int) -> CGFloat {
        toolbarHandleWidth + CGFloat(max(actionCount, 1)) * toolbarSegmentWidth
    }
}
