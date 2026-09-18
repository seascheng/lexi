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
    /// The registry's lucide icon name — rendered with the same
    /// `lucideImage` the live toolbar uses.
    let icon: String
    let isTool: Bool
    var enabled: Bool
}

@MainActor
@Observable
final class ToolbarConfigModel {
    var enabled = true
    var entries: [ToolbarEntry] = []
    var excludedApps: [String] = []
    var newApp = ""
    /// Wired by the pane from the shared settings model — every mutation
    /// nudges the live surfaces via nativeSettingsChanged.
    var effects: LexiSettingsEffects?

    func reload() {
        enabled = LexiStore.settingBool("toolbarEnabled", default: true)
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

    func persistEnabled(_ value: Bool) {
        enabled = value
        LexiStore.setSetting("toolbarEnabled", value ? "true" : "false")
        effects?.nativeSettingsChanged()
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

struct ToolbarConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = ToolbarConfigModel()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.enabled },
                    set: { model.persistEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show selection toolbar")
                        Text("The action bar that appears over selected text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Toolbar")
            }

            Section {
                // Nested real List: Form sections don't support .onMove
                // drag reordering; .mini switches here render 36x16, the
                // same size as the Form switches everywhere else.
                List {
                    ForEach(model.entries) { entry in
                        HStack(spacing: 10) {
                            Image(nsImage: lucideImage(
                                for: entry.icon, title: entry.name,
                                color: .controlAccentColor) ?? NSImage())
                                .frame(width: 20)
                            Text(entry.name)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { entry.enabled },
                                set: { _ in model.toggle(entry) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        .padding(.vertical, 5)
                    }
                    .onMove { from, to in model.move(from: from, to: to) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 300)
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
                    TextField("com.apple.finder", text: $model.newApp)
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
            model.reload()
        }
    }
}

// MARK: - Actions (result card)

@MainActor
@Observable
final class CardConfigModel {
    var features: [LexiFeatureRow] = []
    var origin: CGPoint?
    var size: CGSize?
    /// Wired by the pane — mutations must rebuild the live card's action
    /// bar (refreshCardActions), not just the database.
    var effects: LexiSettingsEffects?

    func reload() {
        features = LexiStore.features().sorted { $0.sortOrder < $1.sortOrder }
        let frame = LexiStore.cardFrame()
        origin = frame.origin
        size = frame.size
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
        for index in features.indices {
            features[index].sortOrder = (index + 1) * 10
        }
        for row in features {
            LexiStore.saveFeature(row)
        }
        effects?.nativeSettingsChanged()
    }

    func resetFrame() {
        LexiStore.resetCardFrame()
        reload()
    }
}

struct CardConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = CardConfigModel()

    var body: some View {
        Form {
            Section {
                ForEach(model.features) { feature in
                    HStack(spacing: 10) {
                        Image(nsImage: lucideImage(
                            for: feature.icon, title: feature.name,
                            color: .controlAccentColor) ?? NSImage())
                            .frame(width: 20)
                        Text(feature.name)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { feature.enabled },
                            set: { _ in model.toggle(feature) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                .onMove { from, to in model.move(from: from, to: to) }
            } header: {
                Text("Action buttons")
            } footer: {
                Text("The AI-feature button group after the card's input field. Toggle to show or hide, drag to reorder — applies on the next card show.")
            }

            Section {
                if let size = model.size {
                    LabeledContent("Size") {
                        Text("\(Int(size.width)) × \(Int(size.height)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let origin = model.origin {
                    LabeledContent("Origin") {
                        Text("\(Int(origin.x)), \(Int(origin.y))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Reset to default frame") { model.resetFrame() }
            } header: {
                Text("Window frame")
            } footer: {
                Text("Drag-resize the card anytime; this forgets the remembered frame.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            model.effects = settings.effects
            model.reload()
        }
    }
}

// MARK: - Clipboard

@MainActor
@Observable
final class ClipboardConfigModel {
    var shortcut = "Alt+V"

    func reload() {
        shortcut = LexiStore.setting("clipboardShortcut") ?? "Alt+V"
    }

    func setShortcut(_ value: String) {
        guard value != shortcut else { return }
        shortcut = value
        LexiStore.setSetting("clipboardShortcut", value)
    }
}

private let clipboardShortcuts: [(String, String)] = [
    ("Alt+V", "⌥V"), ("Ctrl+Shift+V", "⌃⇧V"), ("Alt+Alt", "Double Option"), ("Cmd+Cmd", "Double Command"),
]

struct ClipboardConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = ClipboardConfigModel()

    var body: some View {
        Form {
            Section {
                Picker("Show clipboard", selection: Binding(
                    get: { model.shortcut },
                    set: { settings.setClipboardShortcut($0) }
                )) {
                    ForEach(clipboardShortcuts, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
            } header: {
                Text("Global shortcut")
            } footer: {
                Text("Applies immediately.")
            }

            Section {
                LabeledContent("History") {
                    Text("Unlimited — pinned items survive cleanup")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Capture") {
                    Text("Text and file clips from any app")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Per-app capture rules and retention limits arrive with the Clipboard store's next settings pass.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { model.reload() }
    }
}

// MARK: - Launcher

@MainActor
@Observable
final class LauncherConfigModel {
    var shortcut = "Shift+Shift"

    func reload() {
        shortcut = LexiStore.setting("launcherShortcut") ?? "Shift+Shift"
    }

    func setShortcut(_ value: String) {
        guard value != shortcut else { return }
        shortcut = value
        LexiStore.setSetting("launcherShortcut", value)
    }
}

private let launcherShortcuts: [(String, String)] = [
    ("Shift+Shift", "Double Shift"), ("Alt+Alt", "Double Option"), ("Cmd+Cmd", "Double Command"), ("Cmd+Shift+L", "⌘⇧L"),
]

struct LauncherConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = LauncherConfigModel()

    var body: some View {
        Form {
            Section {
                Picker("Show launcher", selection: Binding(
                    get: { model.shortcut },
                    set: { settings.setLauncherShortcut($0) }
                )) {
                    ForEach(launcherShortcuts, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
            } header: {
                Text("Global shortcut")
            } footer: {
                Text("Applies immediately. Double-tap shortcuts ignore keystrokes while you type.")
            }

            Section {
                LabeledContent("Folder opening") {
                    Text("Default app (Finder)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Sources") {
                    Text("Finder tags · Recents · Favorites")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Per-folder open behaviors (Terminal, default app) arrive with the launcher's next settings pass.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { model.reload() }
    }
}
