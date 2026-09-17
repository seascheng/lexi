import Observation
import SwiftUI

// ---------------------------------------------------------------------------
// Notebook and Configs panes — the React NotebookPage / ConfigsPage
// successors, both on the shared DB through LexiStore.
// ---------------------------------------------------------------------------

@MainActor
@Observable
final class NotebookModel {
    var search = "" { didSet { refilter() } }
    var activeTag = "all" { didSet { refilter() } }
    var allTags: [String] = []
    var displayed: [LexiNote] = []
    var selected: LexiNote?

    private var all: [LexiNote] = []

    /// Eager first load — the hosting structure does not reliably
    /// deliver onAppear (same rationale as VocabularyModel.init).
    init() { reload() }

    func reload() {
        all = LexiStore.notes()
        var tags = Set<String>()
        for note in all { tags.formUnion(note.tags) }
        allTags = tags.sorted()
        if activeTag != "all" && !allTags.contains(activeTag) { activeTag = "all" }
        refilter()
    }

    private func refilter() {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        displayed = all.filter { note in
            let title = note.name.isEmpty ? note.content : note.name
            let matchesQuery = query.isEmpty || title.lowercased().contains(query) || note.content.lowercased().contains(query)
            let matchesTag = activeTag == "all" || note.tags.contains(activeTag)
            return matchesQuery && matchesTag
        }
    }

    func delete(_ note: LexiNote) {
        LexiStore.deleteNote(id: note.id)
        if selected == note { selected = nil }
        reload()
    }
}

struct NotebookPane: View {
    @State private var model = NotebookModel()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Group {
                if model.allTags.isEmpty && model.displayed.isEmpty {
                    ContentUnavailableView(
                        "No notes",
                        systemImage: "notebook-pen",
                        description: Text("Use the toolbar's Note action — selections land here with their tag.")
                    )
                } else {
                    HStack(spacing: 0) {
                        noteList
                            .frame(width: 280)
                        Divider()
                        noteDetail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes", text: Binding(
                get: { model.search },
                set: { model.search = $0 }
            ))
            .textFieldStyle(.plain)
            Divider().frame(height: 14)
            Picker("Tag", selection: Binding(
                get: { model.activeTag },
                set: { model.activeTag = $0 }
            )) {
                Text("All").tag("all")
                ForEach(model.allTags, id: \.self) { tag in
                    Text(tag.capitalized).tag(tag)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }

    private var noteList: some View {
        List(model.displayed, selection: Binding(
            get: { model.selected },
            set: { model.selected = $0 }
        )) { note in
            Button {
                model.selected = note
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.name.isEmpty ? String(note.content.prefix(48)) : note.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !note.tags.isEmpty {
                        Text(note.tags.map(\.capitalized).sorted().joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .tag(note)
            .contextMenu {
                Button("Delete", role: .destructive) { model.delete(note) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var noteDetail: some View {
        if let note = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(note.name.isEmpty ? "Note \(note.id)" : note.name)
                        .font(.title2.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(note.tags, id: \.self) { tag in
                                Text(tag.capitalized)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    Text(note.content)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a note", systemImage: "sidebar.left")
        }
    }
}

// MARK: - Configs (AI features)

@MainActor
@Observable
final class FeaturesModel {
    var rows: [LexiFeatureRow] = []

    func reload() {
        rows = LexiStore.features()
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
}

struct ConfigsPane: View {
    @State private var model = FeaturesModel()
    @State private var editing: LexiFeatureRow?

    var body: some View {
        Group {
            if model.rows.isEmpty {
                ContentUnavailableView(
                    "No features",
                    systemImage: "sparkles",
                    description: Text("Features are the AI actions on the toolbar and the card's Actions tab.")
                )
            } else {
                List {
                    ForEach(model.rows) { row in
                        featureRow(row)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    editing = newFeature()
                } label: {
                    Label("Add Feature", systemImage: "plus")
                }
                Spacer()
                Text("\(model.rows.filter(\.enabled).count) of \(model.rows.count) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.reload() }
        .sheet(item: $editing) { row in
            FeatureEditor(feature: row) { updated in
                model.save(updated)
            } onDelete: { doomed in
                model.delete(doomed)
            }
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

            Image(systemName: iconName(row.icon))
                .foregroundStyle(.tint)
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
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Button("Edit") { editing = row }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
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

    /// Lucide names map to the nearest SF Symbol for the pane.
    private func iconName(_ lucide: String) -> String {
        switch lucide {
        case "languages", "translate": "character.book.closed"
        case "wand", "wand-and-sparkles": "wand.and.stars"
        case "book-open": "book"
        case "brain": "brain"
        case "pencil": "pencil"
        case "sparkles": "sparkles"
        default: "sparkles"
        }
    }
}

// MARK: - Feature editor sheet

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
                    TextField("Icon (Lucide name)", text: $draft.icon)
                }
                Section("Prompt") {
                    TextEditor(text: $draft.promptTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    Text("Use {{text}} for the selected text.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("Output")
                        Spacer()
                        Text(draft.outputMode == "translation_json" ? "structured translation JSON" : "plain text")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                Section("Behavior") {
                    Toggle("Enabled", isOn: $draft.enabled)
                    Toggle("Auto-save single words to vocabulary", isOn: $draft.autoSave)
                    Toggle("Deep thinking mode (slower first token)", isOn: $draft.thinking)
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
