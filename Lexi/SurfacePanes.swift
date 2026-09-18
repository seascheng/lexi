import Observation
import SwiftUI

// ---------------------------------------------------------------------------
// Per-surface config panes. One shared action registry (toolbar_tools blob,
// read through LexiStore) feeds both scopes: the Toolbar pane edits the
// toolbar scope, the Card pane the Actions-tab scope — matching the blob's
// enabled/panelEnabled dual columns. Storage normalization into an `actions`
// table happens together with the Rust cutover (single-writer switch).
// ---------------------------------------------------------------------------

@MainActor
@Observable
final class ToolbarConfigModel {
    var enabled = true
    var tools: [LexiToolEntry] = []
    var excludedApps: [String] = []
    var newApp = ""

    func reload() {
        enabled = LexiStore.settingBool("toolbarEnabled", default: true)
        tools = LexiStore.toolbarTools().sorted { $0.sortOrder < $1.sortOrder }
        excludedApps = LexiStore.excludedToolbarApps()
    }

    func persistEnabled(_ value: Bool) {
        enabled = value
        LexiStore.setSetting("toolbarEnabled", value ? "true" : "false")
    }

    func toggle(_ entry: LexiToolEntry) {
        if let index = tools.firstIndex(where: { $0.id == entry.id }) {
            tools[index].enabled.toggle()
            saveTools()
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        tools.move(fromOffsets: source, toOffset: destination)
        for index in tools.indices {
            tools[index].sortOrder = (index + 1) * 10
        }
        saveTools()
    }

    private func saveTools() {
        LexiStore.saveToolbarTools(tools)
    }

    func addExcludedApp() {
        let app = newApp.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !excludedApps.contains(app) else { return }
        excludedApps.append(app)
        LexiStore.saveExcludedToolbarApps(excludedApps)
        newApp = ""
    }

    func removeExcludedApp(_ app: String) {
        excludedApps.removeAll { $0 == app }
        LexiStore.saveExcludedToolbarApps(excludedApps)
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
                ForEach(model.tools) { tool in
                    HStack(spacing: 10) {
                        Image(systemName: symbol(tool.icon))
                            .foregroundStyle(.tint)
                            .frame(width: 20)
                        Text(tool.displayName)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { tool.enabled },
                            set: { _ in model.toggle(tool) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                .onMove { from, to in model.move(from: from, to: to) }
            } header: {
                Text("Toolbar buttons")
            } footer: {
                Text("Drag to reorder — applies on the next selection. The card's button group is configured in the Actions pane.")
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
        .onAppear { model.reload() }
    }

    private func symbol(_ icon: String) -> String {
        switch icon {
        case "copy": "doc.on.doc"
        case "search": "magnifyingglass"
        case "volume": "speaker.wave.2"
        case "notebook-pen": "notebook-pen"
        case "send": "paperplane"
        default: "sparkles"
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
    }

    func move(from source: IndexSet, to destination: Int) {
        features.move(fromOffsets: source, toOffset: destination)
        for index in features.indices {
            features[index].sortOrder = (index + 1) * 10
        }
        for row in features {
            LexiStore.saveFeature(row)
        }
    }

    func resetFrame() {
        LexiStore.resetCardFrame()
        reload()
    }
}

struct CardConfigPane: View {
    @State private var model = CardConfigModel()

    var body: some View {
        Form {
            Section {
                ForEach(model.features) { feature in
                    HStack(spacing: 10) {
                        Image(systemName: featureIconName(feature.icon))
                            .foregroundStyle(.tint)
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

            Section {
                LabeledContent("Default note category") {
                    Text("Tmp")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notes")
            } footer: {
                Text("Notes created from the toolbar's Note action land under this category in the Clipboard panel.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { model.reload() }
    }

    private func featureIconName(_ lucide: String) -> String {
        switch lucide {
        case "languages", "translate": "character.book.closed"
        case "wand", "wand-and-sparkles": "wand.and.stars"
        case "highlighter": "highlighter"
        case "book-open": "book"
        case "brain": "brain"
        case "pencil": "pencil"
        case "sparkles": "sparkles"
        default: "sparkles"
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
                    set: { model.setShortcut($0) }
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
                    set: { model.setShortcut($0) }
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
