import Observation
import SwiftUI

// ---------------------------------------------------------------------------
// Study panes: the vocabulary table and the SM-2 review flow, both reading
// the shared DB through LexiStore — the React pages' native successors.
// ---------------------------------------------------------------------------

@MainActor
@Observable
final class VocabularyModel {
    var search = "" { didSet { reload() } }
    var statusFilter: String? { didSet { reload() } }
    var rows: [LexiWord] = []
    var counts: [String: Int] = [:]
    var total = 0

    private let pageSize = 60
    private var offset = 0

    var canLoadMore: Bool { rows.count < total }

    /// Eager: the pane's hosting structure (NSHostingView inside a split
    /// item) does not reliably deliver onAppear, so the first load must
    /// not depend on view lifecycle callbacks.
    init() { reload() }

    func reload() {
        offset = 0
        counts = LexiStore.wordCounts()
        total = counts.values.reduce(0, +)
        rows = LexiStore.words(search: search, status: statusFilter, offset: 0, limit: pageSize)
        FileLog.write("VOCAB reload total=\(total) rows=\(rows.count)")
    }

    func loadMore() {
        guard canLoadMore else { return }
        offset += pageSize
        rows.append(contentsOf: LexiStore.words(search: search, status: statusFilter, offset: offset, limit: pageSize))
    }

    func delete(_ word: LexiWord) {
        LexiStore.deleteWord(id: word.id)
        reload()
    }

    var filteredTotal: Int {
        if let statusFilter, !statusFilter.isEmpty {
            return counts[statusFilter] ?? 0
        }
        return total
    }
}

struct VocabularyPane: View {
    @Environment(LexiSettingsModel.self) private var settings
    @State private var model = VocabularyModel()
    @State private var selectedWord: LexiWord?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Group {
                if model.total == 0 {
                    ContentUnavailableView(
                        "No words yet",
                        systemImage: "book",
                        description: Text("Select a word anywhere and run Translate — single words save automatically.")
                    )
                } else {
                    Table(model.rows) {
                        TableColumn("Word") { row in
                            Text(row.word).fontWeight(.medium)
                        }
                        TableColumn("Translation") { row in
                            Text(row.translation).lineLimit(1)
                        }
                        TableColumn("Type") { row in
                            Text(row.entryType.capitalized).foregroundStyle(.secondary)
                        }
                        TableColumn("Status") { row in
                            Text(row.status.capitalized)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((row.status == "mastered" ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                        }
                        TableColumn("Reviews") { row in
                            Text("\(row.reviewCount)").monospacedDigit()
                        }
                        TableColumn("Next") { row in
                            Text(row.nextReview ?? "now").foregroundStyle(.secondary)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if model.canLoadMore {
                            Button("Load more (\(model.rows.count)/\(model.filteredTotal))") {
                                model.loadMore()
                            }
                            .controlSize(.small)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contextMenu(forSelectionType: LexiWord.self) { ids in
            if let selected = ids.first, let word = model.rows.first(where: { $0 == selected }) {
                Button("Delete “\(word.word)”", role: .destructive) {
                    model.delete(word)
                }
            }
        } primaryAction: { _ in }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search word or translation", text: Binding(
                get: { model.search },
                set: { model.search = $0 }
            ))
            .textFieldStyle(.plain)
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 14)
            Picker("Status", selection: Binding(
                get: { model.statusFilter ?? "" },
                set: { model.statusFilter = $0.isEmpty ? nil : $0 }
            )) {
                Text("All (\(model.total))").tag("")
                Text("New (\(model.counts["new"] ?? 0))").tag("new")
                Text("Learning (\(model.counts["learning"] ?? 0))").tag("learning")
                Text("Mastered (\(model.counts["mastered"] ?? 0))").tag("mastered")
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }
}

@MainActor
@Observable
final class ReviewModel {
    var current: LexiWord?
    var revealed = false
    var dueCount = 0

    /// Eager first load — same hosting-structure rationale as
    /// VocabularyModel.init.
    init() { next() }

    func next() {
        current = LexiStore.nextReviewWord()
        revealed = false
        dueCount = LexiStore.dueReviewCount()
        FileLog.write("REVIEW next word=\(current?.word ?? "nil") due=\(dueCount)")
    }

    func grade(_ rating: String) {
        guard let word = current else { return }
        LexiStore.applyReviewGrade(id: word.id, rating: rating)
        next()
    }
}

struct ReviewPane: View {
    @State private var model = ReviewModel()

    var body: some View {
        Group {
            if let word = model.current {
                VStack(spacing: 24) {
                    Text("\(model.dueCount) due")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        Text(word.word)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                        Text(model.revealed ? word.translation : "Tap to reveal")
                            .font(.title3)
                            .foregroundStyle(model.revealed ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .contentShape(Rectangle())
                    .onTapGesture { model.revealed.toggle() }

                    if model.revealed {
                        if !word.definition.isEmpty {
                            Text(word.definition)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 480)
                                .lineLimit(4)
                        }
                        gradeButtons
                    }
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "All reviewed",
                    systemImage: "checkmark.seal",
                    description: Text("Nothing is due — come back tomorrow or add new words from selections.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.next() }
    }

    private var gradeButtons: some View {
        HStack(spacing: 12) {
            ForEach([("again", "Again", Color.red), ("hard", "Hard", Color.orange), ("good", "Good", Color.blue), ("easy", "Easy", Color.green)], id: \.0) { rating, label, color in
                Button(label) {
                    model.grade(rating)
                }
                .controlSize(.large)
                .tint(color)
            }
        }
    }
}
