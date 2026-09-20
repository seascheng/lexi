import Observation
import SwiftUI

// MARK: - Configs (AI features)

@MainActor
@Observable
final class FeaturesModel {
    var rows: [LexiFeatureRow] = []
    /// Per-tool config field edits (id -> field -> value), from the blob.
    var toolConfigs: [(id: String, name: String, icon: String, config: [String: String])] = []

    /// Eager first load — same hosting-structure rationale as
    /// NotebookModel.init.
    init() { reload() }

    func reload() {
        rows = LexiStore.features()
        toolConfigs = LexiStore.toolbarTools().map {
            (id: $0.id, name: $0.displayName,
             icon: $0.icon.isEmpty ? "wand" : $0.icon, config: $0.config)
        }
    }

    func toggle(_ row: LexiFeatureRow) {
        var updated = row
        updated.enabled.toggle()
        LexiStore.saveFeature(updated)
        reload()
    }

    func save(_ row: LexiFeatureRow) {
        LexiStore.saveFeature(row)
        reload()
    }

    func delete(_ row: LexiFeatureRow) {
        LexiStore.deleteFeature(id: row.id)
        reload()
    }

    func setToolField(_ id: String, field: String, value: String) {
        LexiStore.setToolConfigField(id: id, field: field, value: value)
        reload()
    }
}

struct ConfigsPane: View {
    @State private var model = FeaturesModel()
    @State private var editing: LexiFeatureRow?

    var body: some View {
        Form {
            Section("Tools") {
                ForEach(model.toolConfigs, id: \.id) { tool in
                    toolConfigRows(tool)
                }
            }
            Section {
                List {
                    ForEach(model.rows) { row in
                        featureRow(row)
                    }
                }
                .frame(minHeight: 220)
                .listStyle(.inset)
                Button {
                    editing = newFeature()
                } label: {
                    Label("Add Feature", systemImage: "plus")
                }
            } header: {
                Text("AI features")
            } footer: {
                Text("\(model.rows.filter(\.enabled).count) of \(model.rows.count) enabled")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .sheet(item: $editing) { row in
            FeatureEditor(feature: row) { updated in
                model.save(updated)
            } onDelete: { doomed in
                model.delete(doomed)
            }
        }
    }

    /// One row per tool: tool name left, its config control right. Tools
    /// without configuration (copy/note) are a single row — no "No options"
    /// filler.
    @ViewBuilder
    private func toolConfigRows(_ tool: (id: String, name: String, icon: String, config: [String: String])) -> some View {
        switch tool.id {
        case "search":
            LabeledContent {
                Picker("Engine", selection: Binding(
                    get: { tool.config["engine"] ?? "google" },
                    set: { model.setToolField(tool.id, field: "engine", value: $0) }
                )) {
                    Text("Google").tag("google")
                    Text("Bing").tag("bing")
                    Text("DuckDuckGo").tag("duckduckgo")
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } label: {
                Label(tool.name, systemImage: toolIconName(tool.id))
            }
            if tool.config["engine"] == "custom" {
                LabeledContent("URL template") {
                    TextField("", text: Binding(
                        get: { tool.config["customUrl"] ?? "" },
                        set: { model.setToolField(tool.id, field: "customUrl", value: $0) }
                    ), prompt: Text("https://example.com/search?q={query}"))
                    .labelsHidden()
                }
            }
        case "read":
            LabeledContent {
                Picker("TTS engine", selection: Binding(
                    get: { tool.config["engine"] ?? "system" },
                    set: { model.setToolField(tool.id, field: "engine", value: $0) }
                )) {
                    Text("System (say)").tag("system")
                    Text("Volcengine TTS").tag("volcengine")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } label: {
                Label(tool.name, systemImage: toolIconName(tool.id))
            }
            if tool.config["engine"] == "volcengine" {
                LabeledContent("Speech keys") {
                    Text("AI page → Speech section")
                        .foregroundStyle(.secondary)
                }
            }
        case "handoff":
            LabeledContent {
                TextField("", text: Binding(
                    get: { tool.config["targetApp"] ?? "ChatGPT" },
                    set: { model.setToolField(tool.id, field: "targetApp", value: $0) }
                ), prompt: Text("ChatGPT"))
                .labelsHidden()
                .frame(maxWidth: 220)
                .multilineTextAlignment(.trailing)
            } label: {
                Label(tool.name, systemImage: toolIconName(tool.id))
            }
        default:
            Label(tool.name, systemImage: toolIconName(tool.id))
        }
    }

    private func featureRow(_ row: LexiFeatureRow) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { row.enabled },
                set: { _ in model.toggle(row) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Image(nsImage: panelIcon(for: row.icon, title: row.name, color: .controlAccentColor) ?? NSImage())
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.medium)
                Text("\(row.kind) · \(row.outputMode == "translation_json" ? "JSON" : "Text")\(row.autoSave ? " · auto-save" : "")\(row.thinking ? " · thinking" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if row.isBuiltin {
                Text("Built-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Edit") { editing = row }
                .controlSize(.small)
        }
        .padding(.vertical, 5)
    }

    private func newFeature() -> LexiFeatureRow {
        LexiFeatureRow(
            id: "feature-\(Int(Date().timeIntervalSince1970))",
            name: "New Feature",
            kind: "custom",
            promptTemplate: "Process the following text according to the feature name.\n\nText: {{text}}",
            outputMode: "plain_text",
            enabled: true,
            sortOrder: (model.rows.map(\.sortOrder).max() ?? 0) + 10,
            autoSave: false,
            targetLanguage: "",
            icon: "wand",
            isBuiltin: false,
            thinking: false
        )
    }

    private func toolIconName(_ id: String) -> String {
        switch id {
        case "copy": "doc.on.doc"
        case "search": "magnifyingglass"
        case "read": "speaker.wave.2"
        case "note": "note.text"
        case "handoff": "paperplane"
        default: "sparkles"
        }
    }
}

// MARK: - Feature editor sheet

/// Icons a feature can wear: the icon name stored in the DB plus a
/// human label for the picker (rendered with the same panelIcon the
/// card uses).
private let featureIcons: [(icon: String, name: String)] = [
    ("languages", "Translate"),
    ("wand", "Wand"),
    ("highlighter", "Highlight"),
    ("brain", "Think"),
    ("pencil", "Rewrite"),
    ("book-open", "Read"),
    ("sparkles", "Sparkles"),
]

struct FeatureEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LexiFeatureRow
    let onSave: (LexiFeatureRow) -> Void
    let onDelete: (LexiFeatureRow) -> Void

    init(feature: LexiFeatureRow, onSave: @escaping (LexiFeatureRow) -> Void, onDelete: @escaping (LexiFeatureRow) -> Void) {
        _draft = State(initialValue: feature)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Feature") {
                    TextField("Name", text: $draft.name)
                    Picker("Icon", selection: $draft.icon) {
                        ForEach(featureIcons, id: \.icon) { icon in
                            Label {
                                Text(icon.name)
                            } icon: {
                                Image(nsImage: panelIcon(for: icon.icon, title: icon.name, color: .controlAccentColor) ?? NSImage())
                            }
                            .tag(icon.icon)
                        }
                    }
                }
                Section("Prompt") {
                    TextEditor(text: $draft.promptTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                    Text("Use {{text}} for the selected text.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Behavior") {
                    Toggle("Enabled", isOn: $draft.enabled)
                    Toggle("Auto-save single words to vocabulary", isOn: $draft.autoSave)
                    Toggle("Deep thinking mode (slower first token)", isOn: $draft.thinking)
                    LabeledContent("Output") {
                        Text(draft.outputMode == "translation_json" ? "structured translation JSON" : "plain text")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !draft.isBuiltin {
                    Button("Delete", role: .destructive) {
                        onDelete(draft)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 560)
    }
}
