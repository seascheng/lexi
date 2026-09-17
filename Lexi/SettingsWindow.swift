import AppKit
import Observation
import SwiftUI

// ---------------------------------------------------------------------------
// Native settings window — the first surface of the full-Swift migration.
// Architecture follows TinyCast: a programmatic NSWindow (fullSizeContentView
// for the liquid-glass chrome), a real NSSplitViewController hosting SwiftUI
// columns, and an AppKit NSToolbar with back/forward history. The helper is
// an .accessory app, so the window flips the activation policy while open.
// ---------------------------------------------------------------------------

/// Reference-counted policy flips: several windows may want Dock presence.
@MainActor
enum LexiActivationPolicy {
    private static var count = 0

    static func enter() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// One window session's navigation. Released with the window so history
/// never survives a close. `onHistoryChange` lets the AppKit toolbar sync
/// its back/forward buttons (Observation can't reach NSToolbar items).
@MainActor
@Observable
final class SettingsNavigationState {
    private(set) var tab: SettingsTab
    private var history: [SettingsTab] = []
    private var future: [SettingsTab] = []
    var onHistoryChange: (() -> Void)?

    init(tab: SettingsTab) {
        self.tab = tab
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }

    func select(_ tab: SettingsTab) {
        guard tab != self.tab else { return }
        FileLog.write("NAV select \(tab.name) was=\(self.tab.name) cb=\(onHistoryChange != nil)")
        history.append(self.tab)
        future.removeAll()
        self.tab = tab
        onHistoryChange?()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        future.insert(tab, at: 0)
        tab = previous
        onHistoryChange?()
    }

    func goForward() {
        guard let next = future.first else { return }
        future.removeFirst()
        history.append(tab)
        tab = next
        onHistoryChange?()
    }
}

/// The settings sidebar's flat tab list, grouped for display. New pages
/// join here as the migration proceeds.
enum SettingsTab: CaseIterable, Identifiable {
    case general, appearance, ai, shortcuts, vocabulary, review, notebook, configs, toolbar, card, clipboard, launcher

    var id: Self { self }

    /// Lowercase route name — the /debug-shot tab parameter.
    var name: String {
        switch self {
        case .general: "general"
        case .appearance: "appearance"
        case .ai: "ai"
        case .shortcuts: "shortcuts"
        case .vocabulary: "vocabulary"
        case .review: "review"
        case .notebook: "notebook"
        case .configs: "configs"
        case .toolbar: "toolbar"
        case .card: "card"
        case .clipboard: "clipboard"
        case .launcher: "launcher"
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .ai: "AI"
        case .shortcuts: "Shortcuts"
        case .vocabulary: "Vocabulary"
        case .review: "Review"
        case .notebook: "Notebook"
        case .configs: "Configs"
        case .toolbar: "Toolbar"
        case .card: "Card & Notes"
        case .clipboard: "Clipboard"
        case .launcher: "Launcher"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "switch.2"
        case .appearance: "paintbrush"
        case .ai: "sparkles"
        case .shortcuts: "keyboard"
        case .vocabulary: "book"
        case .review: "brain"
        case .notebook: "note.text"
        case .configs: "slider.horizontal.3"
        case .toolbar: "menubar.rectangle"
        case .card: "rectangle.inset.filled"
        case .clipboard: "doc.on.clipboard"
        case .launcher: "rocket"
        }
    }
}

enum SettingsSection: CaseIterable, Identifiable {
    case general, study, surfaces

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .study: "Study"
        case .surfaces: "Surfaces"
        }
    }

    var tabs: [SettingsTab] {
        switch self {
        case .general: [.general, .appearance, .ai, .shortcuts]
        case .study: [.vocabulary, .review, .notebook, .configs]
        case .surfaces: [.toolbar, .card, .clipboard, .launcher]
        }
    }
}

/// Back/forward pair over the detail column — TinyCast's exact recipe:
/// `.sidebarTrackingSeparator` first so the buttons seat in the detail
/// section ahead of the inline title, `.toolbar` bezels, unified bar with
/// the system glass band kept (titlebar NOT transparent).
@MainActor
private final class SettingsToolbar: NSObject, NSToolbarDelegate {
    private static let back = NSToolbarItem.Identifier("LexiSettingsBack")
    private static let forward = NSToolbarItem.Identifier("LexiSettingsForward")

    private let navigation: SettingsNavigationState
    private weak var window: NSWindow?
    private let backButton: NSButton
    private let forwardButton: NSButton

    init(navigation: SettingsNavigationState) {
        self.navigation = navigation
        // Two buttons, not a segmented control: that would draw a divider
        // down the middle.
        backButton = Self.makeButton("chevron.backward", "Back")
        forwardButton = Self.makeButton("chevron.forward", "Forward")
        super.init()
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        navigation.onHistoryChange = { [weak self] in self?.sync() }
    }

    func install(in window: NSWindow) {
        self.window = window
        // All three together are what puts the title inline and leading
        // rather than centred.
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        // `.automatic` draws a hairline once content scrolls under the bar.
        window.titlebarSeparatorStyle = .none
        // Transparent opts the titlebar out of the system's glass band.
        window.titlebarAppearsTransparent = false
        // A drag on a Form shouldn't move the window.
        window.isMovableByWindowBackground = false

        let toolbar = NSToolbar(identifier: "LexiSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        sync()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, Self.back, Self.forward]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.back:
            item.view = backButton
            item.label = "Back"
        case Self.forward:
            item.view = forwardButton
            item.label = "Forward"
        default:
            return nil
        }
        // The one flag that seats an item ahead of the inline title.
        item.isNavigational = true
        item.visibilityPriority = .high
        // Enabled state comes from history, not responder validation.
        item.autovalidates = false
        return item
    }

    @objc private func goBack() { navigation.goBack() }
    @objc private func goForward() { navigation.goForward() }

    private func sync() {
        window?.title = navigation.tab.title
        backButton.isEnabled = navigation.canGoBack
        forwardButton.isEnabled = navigation.canGoForward
        FileLog.write("TITLE sync tab=\(navigation.tab.title) title=\(window?.title ?? "nil")")
    }

    /// Directional symbols so the pair mirrors in RTL.
    private static func makeButton(_ symbol: String, _ label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }
}

/// A real `NSSplitViewController` so the toolbar can use the tracking
/// separator; both columns host SwiftUI trees independently.
@MainActor
private final class SettingsSplitViewController: NSSplitViewController {
    init(sidebar: some View, detail: some View) {
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(rootView: sidebar)
        )
        sidebarItem.minimumThickness = 215
        sidebarItem.maximumThickness = 215
        sidebarItem.canCollapse = false

        let detailItem = NSSplitViewItem(viewController: NSHostingController(rootView: detail))
        detailItem.minimumThickness = 420

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct LexiSidebarList: View {
    @Environment(SettingsNavigationState.self) private var navigation

    var body: some View {
        List(selection: selection) {
            ForEach(SettingsSection.allCases) { section in
                Section(section.title) {
                    ForEach(section.tabs) { tab in
                        HStack(spacing: 7) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 12, weight: .regular))
                                .frame(width: 16)
                                .foregroundStyle(.tint)
                            Text(tab.title)
                                .font(.system(size: 13))
                        }
                        .tag(tab)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .padding(.top, 12)
    }

    /// `List` hands back an optional selection; routed through `select`
    /// so every change lands in history.
    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { navigation.tab },
            set: { if let tab = $0 { navigation.select(tab) } }
        )
    }
}

struct LexiSettingsDetail: View {
    @Environment(SettingsNavigationState.self) private var navigation
    @Environment(LexiSettingsModel.self) private var model

    var body: some View {
        Group {
            switch navigation.tab {
            case .general: GeneralSettingsPane()
            case .appearance: AppearanceSettingsPane()
            case .ai: AISettingsPane()
            case .shortcuts: ShortcutsSettingsPane()
            case .vocabulary: VocabularyPane()
            case .review: ReviewPane()
            case .notebook: NotebookPane()
            case .configs: ConfigsPane()
            case .toolbar: ToolbarConfigPane()
            case .card: CardConfigPane()
            case .clipboard: ClipboardConfigPane()
            case .launcher: LauncherConfigPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectBackground(material: .contentBackground)
                .ignoresSafeArea()
        )
    }
}

/// Behind-window vibrancy behind the detail column, TinyCast-style.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Owns the settings window's lifecycle. Built on first show, torn down on
/// close so the SwiftUI tree deallocates; never quits the app.
@MainActor
final class LexiSettingsWindowController: NSObject, NSWindowDelegate {
    private let contentSize = CGSize(width: 760, height: 540)
    private var window: NSWindow?
    private var navigation: SettingsNavigationState?
    /// NSWindow does NOT retain its toolbar delegate — without this strong
    /// reference the toolbar deallocates right after makeWindow returns,
    /// and its history-sync closure (weak self) becomes a silent no-op
    /// (stale window titles, dead back/forward buttons).
    private var toolbar: SettingsToolbar?
    let model = LexiSettingsModel()

    /// Wired by the app controller: applies a style change in-process and
    /// mirrors it into the Rust caches so helper restarts preserve it.
    var onPanelStyleChange: ((_ theme: String?, _ opacity: Int?, _ blur: String?) -> Void)?
    /// A shortcut or toolbar toggle was persisted; Rust re-reads its statics.
    var onNativeSettingsReload: (() -> Void)?

    /// A fresh window mounts on `tab`; an open one just navigates to it.
    func show(tab: SettingsTab = .general) {
        model.reload()
        if let window {
            navigation?.select(tab)
            LexiActivationPolicy.enter()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let navigation = SettingsNavigationState(tab: tab)
        self.navigation = navigation

        let window = makeWindow(navigation: navigation)
        self.window = window
        window.delegate = self
        LexiActivationPolicy.enter()
        window.makeKeyAndOrderFront(nil)
        // `NSApp.activate` is async — re-assert next turn.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window, self?.window === window else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func focus() -> Bool {
        guard let window else { return false }
        LexiActivationPolicy.enter()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Renders the window's content view to PNG data — own-window capture
    /// needs no screen-recording permission (used by /debug-shot for
    /// layout verification on this headless-debugging setup).
    func snapshotPNG() -> Data? {
        guard let content = window?.contentView else { return nil }
        let rect = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        navigation = nil
        LexiActivationPolicy.leave()
    }

    // MARK: - Private

    private func makeWindow(navigation: SettingsNavigationState) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lexi Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = CGSize(width: 660, height: 480)
        window.setContentSize(contentSize)

        model.effects = LexiSettingsEffects(
            panelStyleChanged: { [weak self] theme, opacity, blur in
                self?.onPanelStyleChange?(theme, opacity, blur)
            },
            nativeSettingsChanged: { [weak self] in
                self?.onNativeSettingsReload?()
            }
        )

        let sidebar = LexiSidebarList()
            .environment(navigation)
            .environment(model)
        let detail = LexiSettingsDetail()
            .environment(navigation)
            .environment(model)

        window.contentViewController = SettingsSplitViewController(sidebar: sidebar, detail: detail)
        // `contentViewController` resets the frame to the fitting size.
        window.setContentSize(contentSize)

        let toolbar = SettingsToolbar(navigation: navigation)
        toolbar.install(in: window)
        self.toolbar = toolbar

        window.setFrameAutosaveName("LexiSettingsWindow")
        if !window.setFrameUsingName("LexiSettingsWindow") {
            window.center()
        }
        return window
    }
}
