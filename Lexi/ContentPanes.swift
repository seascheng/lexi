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
    /// nil = all categories.
    var activeCategoryId: Int64? { didSet { refilter() } }
    var categories: [LexiNoteCategory] = []
    var displayed: [LexiNote] = []
    var selected: LexiNote?

    private var all: [LexiNote] = []

    /// Eager first load — the hosting structure does not reliably
    /// deliver onAppear (same rationale as VocabularyModel.init).
    init() { reload() }

    func reload() {
        all = LexiStore.notes()
        categories = LexiStore.noteCategories()
        if let active = activeCategoryId, !categories.contains(where: { $0.id == active }) {
            activeCategoryId = nil
        }
        refilter()
    }

    private func refilter() {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        displayed = all.filter { note in
            let title = note.name.isEmpty ? note.content : note.name
            let matchesQuery = query.isEmpty || title.lowercased().contains(query) || note.content.lowercased().contains(query)
            let matchesCategory = activeCategoryId == nil || note.categoryId == activeCategoryId
            return matchesQuery && matchesCategory
        }
    }

    func delete(_ note: LexiNote) {
        LexiStore.deleteNote(id: note.id)
        if selected == note { selected = nil }
        reload()
    }

    /// Detail-editor save: name/content write, then reload with the edited
    /// note kept selected.
    func update(_ note: LexiNote, name: String, content: String) {
        LexiStore.updateNoteName(id: note.id, name: name)
        LexiStore.updateNoteContent(id: note.id, content: content)
        reload()
        selected = all.first(where: { $0.id == note.id })
    }

    /// Category dropdown change: re-file the note, reload, keep selection.
    func setCategory(of note: LexiNote, to categoryId: Int64?) {
        LexiStore.setNoteCategory(id: note.id, categoryId: categoryId)
        reload()
        selected = all.first(where: { $0.id == note.id })
    }

    func addCategory(_ name: String) {
        LexiStore.createNoteCategory(name: name)
        reload()
    }

    func renameCategory(_ category: LexiNoteCategory, to name: String) {
        LexiStore.renameNoteCategory(id: category.id, name: name)
        reload()
        if let id = selected?.id { selected = all.first(where: { $0.id == id }) }
    }

    /// Category removal deletes every note filed under it.
    func deleteCategory(_ category: LexiNoteCategory) {
        LexiStore.deleteNoteCategory(id: category.id)
        if selected?.categoryId == category.id { selected = nil }
        reload()
    }
}

/// Editable note detail: name + category dropdown + content editor + Save,
/// laid out with the same grouped Form as every other settings pane.
/// The caller applies `.id(note.id)` so a selection change recreates the
/// view — its @State drafts must not leak across notes.
private struct NoteDetailEditor: View {
    let note: LexiNote
    let categories: [LexiNoteCategory]
    let onSave: (String, String) -> Void
    let onCategoryChange: (Int64?) -> Void

    @State private var name: String
    @State private var content: String
    @State private var saved = false

    init(
        note: LexiNote,
        categories: [LexiNoteCategory],
        onSave: @escaping (String, String) -> Void,
        onCategoryChange: @escaping (Int64?) -> Void
    ) {
        self.note = note
        self.categories = categories
        self.onSave = onSave
        self.onCategoryChange = onCategoryChange
        _name = State(initialValue: note.name)
        _content = State(initialValue: note.content)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Picker("Category", selection: Binding(
                    get: { note.categoryId },
                    set: { onCategoryChange($0) }
                )) {
                    Text("Uncategorized").tag(Int64?.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Int64?.some(category.id))
                    }
                }
            } header: {
                Text("Note")
            }
            Section {
                TextEditor(text: $content)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
            } header: {
                Text("Content")
            }
            Section {
                HStack {
                    if saved {
                        Text("Saved")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Save") {
                        onSave(name, content)
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

struct NotebookPane: View {
    @State private var model = NotebookModel()
    @State private var managingCategories = false

    var body: some View {
        Group {
            if model.categories.isEmpty && model.displayed.isEmpty {
                ContentUnavailableView(
                    "No notes",
                    systemImage: "notebook-pen",
                    description: Text("Use the toolbar's Note action — selections land here.")
                )
            } else {
                VStack(spacing: 0) {
                    filterBar
                    HStack(spacing: 0) {
                        noteList
                            .frame(width: 280)
                        Divider()
                        noteDetail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .sheet(isPresented: $managingCategories) {
            CategoryManager(model: model)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("Search notes", text: Binding(
                get: { model.search },
                set: { model.search = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 200)

            Picker("Category", selection: Binding(
                get: { model.activeCategoryId },
                set: { model.activeCategoryId = $0 }
            )) {
                Text("All").tag(Int64?.none)
                ForEach(model.categories) { category in
                    Text(category.name).tag(Int64?.some(category.id))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            Button {
                model.reload()
                managingCategories = true
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Manage categories")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var noteList: some View {
        List(model.displayed, selection: Binding(
            get: { model.selected },
            set: { model.selected = $0 }
        )) { note in
            VStack(alignment: .leading, spacing: 2) {
                Text(note.name.isEmpty ? String(note.content.prefix(48)) : note.name)
                    .lineLimit(1)
                if let category = note.categoryName {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .tag(note)
            .contextMenu {
                Button("Delete", role: .destructive) { model.delete(note) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var noteDetail: some View {
        if let note = model.selected {
            NoteDetailEditor(
                note: note,
                categories: model.categories,
                onSave: { name, content in
                    model.update(note, name: name, content: content)
                },
                onCategoryChange: { categoryId in
                    model.setCategory(of: note, to: categoryId)
                }
            )
            // Identity at the call site: a selection change must recreate
            // the editor's @State, not re-init it in place.
            .id(note.id)
        } else {
            ContentUnavailableView("Select a note", systemImage: "sidebar.left")
        }
    }
}

/// Top-bar category management: add, rename (commit with Return), delete.
/// Deleting a category deletes every note filed under it — confirmed first.
private struct CategoryManager: View {
    let model: NotebookModel

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    /// Rename drafts keyed by category id — committed on Return so
    /// keystrokes don't trigger reloads mid-edit.
    @State private var drafts: [Int64: String] = [:]
    @State private var pendingDelete: LexiNoteCategory?
    @FocusState private var newNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Categories")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            HStack {
                TextField("New category", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($newNameFocused)
                    .onSubmit { add() }
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.categories.isEmpty {
                Text("No categories yet — notes stay uncategorized until filed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.categories) { category in
                    HStack(spacing: 8) {
                        TextField(category.name, text: draftBinding(category))
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                            .onSubmit { commitRename(category) }
                        Text("\(category.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = category
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete category and \(pendingDelete.map { "\($0.count) " } ?? "")notes", role: .destructive) {
                if let category = pendingDelete { model.deleteCategory(category) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var deleteTitle: String {
        guard let category = pendingDelete else { return "" }
        return "Delete “\(category.name)”? Its \(category.count) note\(category.count == 1 ? "" : "s") will be deleted too."
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.addCategory(name)
        newName = ""
        newNameFocused = true
    }

    private func draftBinding(_ category: LexiNoteCategory) -> Binding<String> {
        Binding(
            get: { drafts[category.id] ?? category.name },
            set: { drafts[category.id] = $0 }
        )
    }

    private func commitRename(_ category: LexiNoteCategory) {
        guard let draft = drafts[category.id] else { return }
        drafts[category.id] = nil
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != category.name else { return }
        model.renameCategory(category, to: name)
    }
}

// MARK: - Configs (AI features)

@MainActor
@Observable
final class FeaturesModel {
    var rows: [LexiFeatureRow] = []
    /// Per-tool config field edits (id -> field -> value), from the blob.
    var toolConfigs: [(id: String, name: String, icon: String, config: [String: String])] = []

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
        .onAppear { model.reload() }
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
                .controlSize(.small)
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
                .controlSize(.small)
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
            .controlSize(.small)

            Image(systemName: iconName(row.icon))
                .foregroundStyle(.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.medium)
                Text("\(row.kind) · \(row.outputMode == "translation_json" ? "JSON" : "Text")\(row.autoSave ? " · auto-save" : "")\(row.speechEnabled ? " · speech" : "")\(row.thinking ? " · thinking" : "")")
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
            thinking: false,
            speechEnabled: false
        )
    }

    /// Lucide names map to the nearest SF Symbol for the pane.
    private func iconName(_ lucide: String) -> String {
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

/// Icons a feature can wear: the lucide name stored in the DB, the SF
/// Symbol it renders as, and a human label for the picker.
private let featureIcons: [(lucide: String, symbol: String, name: String)] = [
    ("languages", "character.book.closed", "Translate"),
    ("wand", "wand.and.stars", "Wand"),
    ("highlighter", "highlighter", "Highlight"),
    ("brain", "brain", "Think"),
    ("pencil", "pencil", "Rewrite"),
    ("book-open", "book", "Read"),
    ("sparkles", "sparkles", "Sparkles"),
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
                        ForEach(featureIcons, id: \.lucide) { icon in
                            Label(icon.name, systemImage: icon.symbol).tag(icon.lucide)
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
                    Toggle("Speak result (text to speech)", isOn: $draft.speechEnabled)
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
