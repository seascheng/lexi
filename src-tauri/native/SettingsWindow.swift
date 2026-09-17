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
    case general, appearance, ai, shortcuts, vocabulary, review

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .ai: "AI"
        case .shortcuts: "Shortcuts"
        case .vocabulary: "Vocabulary"
        case .review: "Review"
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
        }
    }
}

enum SettingsSection: CaseIterable, Identifiable {
    case general, study

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .study: "Study"
        }
    }

    var tabs: [SettingsTab] {
        switch self {
        case .general: [.general, .appearance, .ai, .shortcuts]
        case .study: [.vocabulary, .review]
        }
    }
}

/// Back/forward pair over the detail column; the tracking separator makes
/// the sidebar run edge-to-edge under its own clean material.
@MainActor
private final class SettingsToolbar: NSObject, NSToolbarDelegate {
    private static let back = NSToolbarItem.Identifier("LexiSettingsBack")
    private static let forward = NSToolbarItem.Identifier("LexiSettingsForward")

    private let navigation: SettingsNavigationState
    private let backButton = SettingsToolbar.makeButton("chevron.backward", "Back")
    private let forwardButton = SettingsToolbar.makeButton("chevron.forward", "Forward")

    init(navigation: SettingsNavigationState) {
        self.navigation = navigation
        super.init()
        backButton.action = #selector(goBack)
        backButton.target = self
        forwardButton.action = #selector(goForward)
        forwardButton.target = self
        navigation.onHistoryChange = { [weak self] in self?.sync() }
        sync()
    }

    func install(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "LexiSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        // `.preference` keeps the bar compact like System Settings' panes.
        window.toolbarStyle = .preference
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.back, Self.forward, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.back: return backButtonItem()
        case Self.forward: return forwardButtonItem()
        default: return nil
        }
    }

    private func backButtonItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.back)
        item.view = backButton
        item.label = "Back"
        item.paletteLabel = "Back"
        return item
    }

    private func forwardButtonItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.forward)
        item.view = forwardButton
        item.label = "Forward"
        item.paletteLabel = "Forward"
        return item
    }

    @objc private func goBack() { navigation.goBack() }
    @objc private func goForward() { navigation.goForward() }

    private func sync() {
        backButton.isEnabled = navigation.canGoBack
        forwardButton.isEnabled = navigation.canGoForward
    }

    /// Directional symbols so the pair mirrors in RTL.
    private static func makeButton(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBar
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
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
                        Label(tab.title, systemImage: tab.systemImage)
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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
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

        window.setFrameAutosaveName("LexiSettingsWindow")
        if !window.setFrameUsingName("LexiSettingsWindow") {
            window.center()
        }
        return window
    }
}
