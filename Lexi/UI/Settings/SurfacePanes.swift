import Observation
import SwiftUI

// ---------------------------------------------------------------------------
// Per-surface config panes. One shared action registry (toolbar_tools blob,
// read through LexiStore) feeds both scopes: the Toolbar pane edits the
// toolbar scope, the Card pane the Actions-tab scope — matching the blob's
// enabled/panelEnabled dual columns. Storage normalization into an `actions`
// table happens together with the Rust cutover (single-writer switch).
// ---------------------------------------------------------------------------

/// One row of the unified toolbar list: a built-in tool or an AI feature.
struct ToolbarEntry: Identifiable {
    let id: String
    let name: String
    /// The registry's icon name — rendered with the same
    /// `panelIcon` the live toolbar uses.
    let icon: String
    let isTool: Bool
    var enabled: Bool
}

@MainActor
@Observable
final class ToolbarConfigModel {
    var entries: [ToolbarEntry] = []
    var excludedApps: [String] = []
    var newApp = ""
    /// Wired by the pane from the shared settings model — every mutation
    /// nudges the live surfaces via nativeSettingsChanged.
    var effects: LexiSettingsEffects?

    /// Eager first load — the pane's hosting structure (NSHostingView
    /// inside a split item) does not reliably deliver onAppear, so the
    /// first load must not depend on view lifecycle callbacks.
    init() { reload() }

    func reload() {
        // One source of truth: the shared toolbarOrder id list. Entries
        // missing from it (fresh tools/features) append in registry order.
        let tools = LexiStore.toolbarTools().sorted { $0.sortOrder < $1.sortOrder }
        let features = LexiStore.features().sorted { $0.sortOrder < $1.sortOrder }
        var byId: [String: ToolbarEntry] = [:]
        for tool in tools {
            byId[tool.id] = ToolbarEntry(
                id: tool.id, name: tool.displayName,
                icon: tool.icon, isTool: true, enabled: tool.enabled)
        }
        for feature in features {
            byId[feature.id] = ToolbarEntry(
                id: feature.id, name: feature.name,
                icon: feature.icon, isTool: false, enabled: feature.enabled)
        }
        var ordered: [ToolbarEntry] = []
        for id in LexiStore.toolbarOrder() {
            if let entry = byId.removeValue(forKey: id) {
                ordered.append(entry)
            }
        }
        ordered.append(contentsOf: byId.values.sorted { $0.id < $1.id })
        entries = ordered
        excludedApps = LexiStore.excludedToolbarApps()
    }

    func toggle(_ entry: ToolbarEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].enabled.toggle()
        if entries[index].isTool {
            var tools = LexiStore.toolbarTools()
            if let i = tools.firstIndex(where: { $0.id == entry.id }) {
                tools[i].enabled = entries[index].enabled
                LexiStore.saveToolbarTools(tools)
            }
        } else {
            var rows = LexiStore.features()
            if let i = rows.firstIndex(where: { $0.id == entry.id }) {
                rows[i].enabled = entries[index].enabled
                LexiStore.saveFeature(rows[i])
            }
        }
        effects?.nativeSettingsChanged()
    }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        // Persist the dragged sequence as THE toolbar order — no per-store
        // sort_order renumbering (two numbering spaces merged numerically
        // is exactly the desync this replaces).
        LexiStore.saveToolbarOrder(entries.map(\.id))
        effects?.nativeSettingsChanged()
    }

    func addExcludedApp() {
        let app = newApp.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !excludedApps.contains(app) else { return }
        excludedApps.append(app)
        LexiStore.saveExcludedToolbarApps(excludedApps)
        newApp = ""
        effects?.nativeSettingsChanged()
    }

    func removeExcludedApp(_ app: String) {
        excludedApps.removeAll { $0 == app }
        LexiStore.saveExcludedToolbarApps(excludedApps)
        effects?.nativeSettingsChanged()
    }
}

/// Shared drag-to-reorder toggle row list: icon + name + switch, dragged
/// with `.onMove`. Form sections don't support .onMove reordering on
/// macOS, so both the Toolbar and Actions panes nest a real List inside
/// their Form section — this is that nested List, factored out so the row
/// height and metrics live in one place.
private struct ReorderableToggleList<Item: Identifiable>: View {
    static var rowHeight: CGFloat { 38 }

    let items: [Item]
    let icon: (Item) -> String
    let name: (Item) -> String
    let isEnabled: (Item) -> Bool
    let onToggle: (Item) -> Void
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        List {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(nsImage: panelIcon(for: icon(item), title: name(item), color: .controlAccentColor) ?? NSImage())
                        .frame(width: 20)
                    Text(name(item))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isEnabled(item) },
                        set: { _ in onToggle(item) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.vertical, 5)
            }
            .onMove(perform: onMove)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(height: CGFloat(items.count) * Self.rowHeight + 12)
    }
}

struct ToolbarConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = ToolbarConfigModel()

    var body: some View {
        Form {
            Section {
                // Nested real List: Form sections don't support .onMove
                // drag reordering; .mini switches here render 36x16, the
                // same size as the Form switches everywhere else.
                ReorderableToggleList(
                    items: model.entries,
                    icon: { $0.icon },
                    name: { $0.name },
                    isEnabled: { $0.enabled },
                    onToggle: { model.toggle($0) },
                    onMove: { from, to in model.move(from: from, to: to) }
                )
            } header: {
                Text("Toolbar buttons")
            } footer: {
                Text("Built-in tools and AI features share one bar. Toggle to show or hide, drag to reorder — applies on the next selection. The card's button group is configured in the Actions pane.")
            }

            Section {
                ForEach(model.excludedApps, id: \.self) { app in
                    HStack {
                        Text(app).font(.callout).monospaced()
                        Spacer()
                        Button(role: .destructive) {
                            model.removeExcludedApp(app)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Bundle identifier", text: $model.newApp)
                    Button("Add") { model.addExcludedApp() }
                        .disabled(model.newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("Bundle identifiers where the toolbar never appears.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            model.effects = settings.effects
        }
    }
}

// MARK: - Actions (result card)

@MainActor
@Observable
final class CardConfigModel {
    var features: [LexiFeatureRow] = []
    /// Wired by the pane — mutations must rebuild the live card's action
    /// bar (refreshCardActions), not just the database.
    var effects: LexiSettingsEffects?

    /// Eager first load — same hosting-structure rationale as
    /// ToolbarConfigModel.init.
    init() { reload() }

    func reload() {
        // Same source as the live card bar: the shared toolbarOrder list,
        // filtered to features.
        let all = LexiStore.features()
        var byId: [String: LexiFeatureRow] = [:]
        for row in all { byId[row.id] = row }
        var ordered: [LexiFeatureRow] = []
        for id in LexiStore.toolbarOrder() {
            if let row = byId.removeValue(forKey: id) {
                ordered.append(row)
            }
        }
        features = ordered + byId.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    func toggle(_ row: LexiFeatureRow) {
        var updated = row
        updated.enabled.toggle()
        LexiStore.saveFeature(updated)
        reload()
        effects?.nativeSettingsChanged()
    }

    func move(from source: IndexSet, to destination: Int) {
        features.move(fromOffsets: source, toOffset: destination)
        // Splice the new feature order back into the shared toolbarOrder at
        // the first feature position — tools keep their slots, the card
        // bar and this pane stay in lockstep.
        var full = LexiStore.toolbarOrder()
        let featureIds = features.map(\.id)
        let anchor = full.firstIndex(where: { featureIds.contains($0) }) ?? full.count
        full.removeAll { featureIds.contains($0) }
        full.insert(contentsOf: featureIds, at: min(anchor, full.count))
        for id in featureIds where !full.contains(id) {
            full.append(id)
        }
        LexiStore.saveToolbarOrder(full)
        effects?.nativeSettingsChanged()
    }
}

struct CardConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = CardConfigModel()

    var body: some View {
        Form {
            Section {
                // Nested real List: Form sections don't support .onMove
                // drag reordering on macOS. Same pattern as the Toolbar
                // pane's button list.
                ReorderableToggleList(
                    items: model.features,
                    icon: { $0.icon },
                    name: { $0.name },
                    isEnabled: { $0.enabled },
                    onToggle: { model.toggle($0) },
                    onMove: { from, to in model.move(from: from, to: to) }
                )
            } header: {
                Text("Action buttons")
            } footer: {
                Text("The AI-feature button group after the card's input field. Toggle to show or hide, drag to reorder — applies on the next card show.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            model.effects = settings.effects
        }
    }
}

// MARK: - Launcher

/// Launcher surface settings — grows as the panel gains features. The
/// first group controls which sections the folder page shows; the live
/// panel re-reads them on every show, so toggles apply immediately.
@MainActor
@Observable
final class LauncherConfigModel {
    var showFavorites = true
    var showRecents = true
    var showTagged = true
    /// One tag section: toggle + drag order. The launcher publishes the
    /// known set (`launcher.knownTags`, written when its Spotlight query
    /// lands); a brand-new tag appears here on the next launcher open.
    struct TagEntry: Identifiable {
        let name: String
        var enabled: Bool
        var id: String { name }
    }
    var tagEntries: [TagEntry] = []
    /// Wired by the pane from the shared settings model.
    var effects: LexiSettingsEffects?

    /// Eager first load — the pane's hosting structure does not reliably
    /// deliver onAppear (same reason as ToolbarConfigModel).
    init() { reload() }

    func reload() {
        showFavorites = LexiStore.settingBool("launcher.showFavorites", default: true)
        showRecents = LexiStore.settingBool("launcher.showRecents", default: true)
        showTagged = LexiStore.settingBool("launcher.showTagged", default: true)
        let known = LexiStore.tagList("launcher.knownTags")
        let order = LexiStore.tagList("launcher.tagOrder")
        let disabled = Set(LexiStore.tagList("launcher.disabledTags"))
        let ordered = order.filter { known.contains($0) } + known.filter { !order.contains($0) }
        tagEntries = ordered.map { TagEntry(name: $0, enabled: !disabled.contains($0)) }
    }

    private func set(_ key: String, _ value: Bool) {
        LexiStore.setSetting(key, value ? "true" : "false")
        effects?.nativeSettingsChanged()
    }

    func setShowFavorites(_ value: Bool) {
        showFavorites = value
        set("launcher.showFavorites", value)
    }

    func setShowRecents(_ value: Bool) {
        showRecents = value
        set("launcher.showRecents", value)
    }

    func setShowTagged(_ value: Bool) {
        showTagged = value
        set("launcher.showTagged", value)
    }

    private func persistTags() {
        LexiStore.saveTagList(
            tagEntries.map(\.name), for: "launcher.tagOrder")
        LexiStore.saveTagList(
            tagEntries.filter { !$0.enabled }.map(\.name), for: "launcher.disabledTags")
        effects?.nativeSettingsChanged()
    }

    func toggleTag(_ entry: TagEntry) {
        guard let index = tagEntries.firstIndex(where: { $0.name == entry.name }) else { return }
        tagEntries[index].enabled.toggle()
        persistTags()
    }

    func moveTag(from source: IndexSet, to destination: Int) {
        tagEntries.move(fromOffsets: source, toOffset: destination)
        persistTags()
    }
}

struct LauncherConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = LauncherConfigModel()

    var body: some View {
        Form {
            Section {
                Toggle("Favorites", isOn: Binding(
                    get: { model.showFavorites },
                    set: { model.setShowFavorites($0) }
                ))
                Toggle("Recent", isOn: Binding(
                    get: { model.showRecents },
                    set: { model.setShowRecents($0) }
                ))
                Toggle("Tagged folders", isOn: Binding(
                    get: { model.showTagged },
                    set: { model.setShowTagged($0) }
                ))
            } header: {
                Text("Folder page sections")
            } footer: {
                Text("Which groups the launcher's folder page shows — and which folders its search draws from. Applies on the next open.")
            }
            Section {
                if model.tagEntries.isEmpty {
                    Text("No Finder tags yet — open the launcher once and they will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ReorderableToggleList(
                        items: model.tagEntries,
                        icon: { _ in "folder" },
                        name: { $0.name },
                        isEnabled: { $0.enabled },
                        onToggle: { model.toggleTag($0) },
                        onMove: { from, to in model.moveTag(from: from, to: to) }
                    )
                }
            } header: {
                Text("Tag sections")
            } footer: {
                Text("Each Finder tag's folder group: toggle to show or hide, drag to set the display order.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            model.effects = settings.effects
        }
    }
}

// MARK: - Finder extension

/// Finder 右键扩展设置。状态不进 SQLite —— 单一事实源是 App Group
/// 容器里的 JSON（沙盒 appex 读得到），每个 setter 整体落盘；扩展
/// 在每次右键时现读，改动即时生效。
@MainActor
@Observable
final class FinderConfigModel {
    var copyPath = true
    var newFile = true
    var openInTerminal = true
    var openInEditor = true
    /// 逗号/空格分隔的编辑缓冲，提交时解析落盘。
    var newFileExtsText = "txt, md"
    var terminalBundleId = "com.apple.Terminal"
    var editorBundleId = "com.apple.TextEdit"

    /// 可选终端/编辑器：只列本机已装的（bundle id 探测），
    /// 当前选中值即使未装也保留展示。
    static let terminalChoices = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("org.alacritty", "Alacritty"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("com.github.wez.wezterm", "WezTerm"),
    ]
    static let editorChoices = [
        ("com.apple.TextEdit", "TextEdit"),
        ("com.microsoft.VSCode", "VS Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code - Insiders"),
        ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text 4"),
        ("com.sublimetext.3", "Sublime Text 3"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.panic.Nova", "Nova"),
        ("com.barebones.bbedit", "BBEdit"),
        ("abnerworks.Typora", "Typora"),
    ]

    init() { reload() }

    func reload() {
        let config = FinderSyncConfig.load()
        copyPath = config.copyPath
        newFile = config.newFile
        openInTerminal = config.openInTerminal
        openInEditor = config.openInEditor
        newFileExtsText = config.newFileExts.joined(separator: ", ")
        terminalBundleId = config.terminalBundleId
        editorBundleId = config.editorBundleId
    }

    private func update(_ mutate: (inout FinderSyncConfig) -> Void) {
        var config = FinderSyncConfig.load()
        mutate(&config)
        config.save()
        reload()
    }

    func setCopyPath(_ value: Bool) { copyPath = value; update { $0.copyPath = value } }
    func setNewFile(_ value: Bool) { newFile = value; update { $0.newFile = value } }
    func setOpenInTerminal(_ value: Bool) { openInTerminal = value; update { $0.openInTerminal = value } }
    func setOpenInEditor(_ value: Bool) { openInEditor = value; update { $0.openInEditor = value } }

    func setTerminal(_ bundleId: String) { terminalBundleId = bundleId; update { $0.terminalBundleId = bundleId } }
    func setEditor(_ bundleId: String) { editorBundleId = bundleId; update { $0.editorBundleId = bundleId } }

    /// 解析扩展名输入：按逗号/空格切分、去点、转小写、去重、剔空。
    func commitExts() {
        let parsed = newFileExtsText
            .split(whereSeparator: { ", ，".contains($0) })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) .lowercased() }
            .filter { !$0.isEmpty }
        let exts = Array(Set(parsed)).sorted()
        newFileExtsText = exts.joined(separator: ", ")
        update { $0.newFileExts = exts.isEmpty ? ["txt"] : exts }
    }

    static func isInstalled(_ bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
}

struct FinderConfigPane: View {
    @State private var model = FinderConfigModel()

    private func choicePicker(
        _ title: String, selection: Binding<String>, choices: [(String, String)]
    ) -> some View {
        Picker(title, selection: selection) {
            // 当前值未装时保留展示，避免 Picker 无选中项。
            let extra = !FinderConfigModel.isInstalled(selection.wrappedValue)
                && !choices.contains(where: { $0.0 == selection.wrappedValue })
                ? [(selection.wrappedValue, selection.wrappedValue)] : []
            ForEach(choices + extra, id: \.0) { choice in
                Text(choice.1).tag(choice.0)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Copy path", isOn: Binding(
                    get: { model.copyPath }, set: { model.setCopyPath($0) }))
                Toggle("New file", isOn: Binding(
                    get: { model.newFile }, set: { model.setNewFile($0) }))
                Toggle("Open in terminal", isOn: Binding(
                    get: { model.openInTerminal }, set: { model.setOpenInTerminal($0) }))
                Toggle("Open in editor", isOn: Binding(
                    get: { model.openInEditor }, set: { model.setOpenInEditor($0) }))
            } header: {
                Text("Menu items")
            } footer: {
                Text("Which items the Lexi Finder context menu shows. Changes apply on the next right-click.")
            }
            Section {
                TextField("txt, md, …", text: $model.newFileExtsText)
                    .onSubmit { model.commitExts() }
            } header: {
                Text("New file types")
            } footer: {
                Text("Comma-separated extensions for the New File submenu. Files are created empty; press Return to apply.")
            }
            Section {
                choicePicker("Terminal", selection: Binding(
                    get: { model.terminalBundleId }, set: { model.setTerminal($0) }),
                    choices: FinderConfigModel.terminalChoices)
                choicePicker("Editor", selection: Binding(
                    get: { model.editorBundleId }, set: { model.setEditor($0) }),
                    choices: FinderConfigModel.editorChoices)
            } header: {
                Text("Open with")
            } footer: {
                Text("Apps used by the Open-in-Terminal and Open-in-Editor commands; only installed apps are listed. Falls back to Terminal/TextEdit when missing.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
