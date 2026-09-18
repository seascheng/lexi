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
    var entries: [ToolbarEntry] = []
    var excludedApps: [String] = []
    var newApp = ""
    /// Wired by the pane from the shared settings model — every mutation
    /// nudges the live surfaces via nativeSettingsChanged.
    var effects: LexiSettingsEffects?

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

struct ToolbarConfigPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = ToolbarConfigModel()

    var body: some View {
        Form {
            Section {
                // Nested real List: Form sections don't support .onMove
                // drag reordering; .mini switches here render 36x16, the
                // same size as the Form switches everywhere else.
                List {
                    ForEach(model.entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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
                .frame(height: CGFloat(model.entries.count) * 38 + 12)
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
            model.reload()
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
                List {
                    ForEach(model.features) { feature in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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
                            .controlSize(.mini)
                        }
                        .padding(.vertical, 5)
                    }
                    .onMove { from, to in model.move(from: from, to: to) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(model.features.count) * 38 + 12)
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
            model.reload()
        }
    }
}
