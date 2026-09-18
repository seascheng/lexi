import Observation
import SwiftUI

// ---------------------------------------------------------------------------
// Study panes: the vocabulary expansion list and the SM-2 review flow, both
// reading the shared DB through LexiStore — the React pages' native
// successors. Layout parity with VocabularyPage.tsx: one expandedId, a
// collapsed row per word (chevron + word + inline-markdown translation +
// status badge), a detail block when expanded, Prev/Next pagination.
// ---------------------------------------------------------------------------

@MainActor
@Observable
final class VocabularyModel {
    var search = "" { didSet { reload() } }
    var statusFilter: String = "all" { didSet { reload() } }
    var entryTypeFilter: String = "all" { didSet { reload() } }
    var page = 1 { didSet { reload() } }
    var rows: [LexiWord] = []
    var counts: [String: Int] = [:]
    var total = 0
    var expandedId: Int64?

    private let pageSize = 30

    var totalPages: Int { max(1, (total + pageSize - 1) / pageSize) }
    var safePage: Int { min(page, totalPages) }

    /// Eager: the pane's hosting structure (NSHostingView inside a split
    /// item) does not reliably deliver onAppear, so the first load must
    /// not depend on view lifecycle callbacks.
    init() { reload() }

    func reload() {
        counts = LexiStore.wordCounts()
        let status = statusFilter == "all" ? nil : statusFilter
        let entryType = entryTypeFilter == "all" ? nil : entryTypeFilter
        total = counts.values.reduce(0, +)
        let filtered = status.map { counts[$0] ?? 0 } ?? total
        total = status == nil ? total : filtered
        let offset = (safePage - 1) * pageSize
        rows = LexiStore.words(search: search, status: status, entryType: entryType, offset: offset, limit: pageSize)
        FileLog.write("VOCAB reload page=\(safePage) total=\(total) rows=\(rows.count)")
    }

    func toggleExpand(_ word: LexiWord) {
        expandedId = expandedId == word.id ? nil : word.id
    }

    func delete(_ word: LexiWord) {
        LexiStore.deleteWord(id: word.id)
        if expandedId == word.id { expandedId = nil }
        reload()
    }

    func setStatus(_ word: LexiWord, to status: String) {
        LexiStore.setWordStatus(id: word.id, status: status)
        reload()
    }
}

struct VocabularyPane: View {
    @State private var model = VocabularyModel()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if model.rows.isEmpty {
                ContentUnavailableView(
                    "No matching entries",
                    systemImage: "book",
                    description: Text("Select a word anywhere and run Translate — single words save automatically.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { word in
                            wordRow(word)
                            Divider().opacity(0.4)
                        }
                    }
                }
                paginationBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Collapsed row + expanded detail (React parity)

    private func wordRow(_ word: LexiWord) -> some View {
        let isExpanded = model.expandedId == word.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.toggleExpand(word) }
            } label: {
                HStack(spacing: 8) {
                    // The text group absorbs all flexible width and truncates;
                    // the badge keeps its ideal size and never leaves the pane.
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(word.word)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if !word.translation.isEmpty {
                            MarkdownText(content: word.translation, compact: true, inline: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusBadge(word.status)
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                expandedDetail(word)
                    .padding(.leading, 28)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(isExpanded ? Color.primary.opacity(0.04) : Color.clear)
    }

    private func expandedDetail(_ word: LexiWord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !word.note.isEmpty {
                MarkdownText(content: word.note, compact: true)
            } else {
                if !word.pos.isEmpty {
                    Text(word.pos)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                if !word.translation.isEmpty {
                    MarkdownText(content: word.translation, compact: true)
                }
                if !word.definition.isEmpty {
                    MarkdownText(content: word.definition, compact: true)
                        .opacity(0.8)
                }
            }
            if !word.example.isEmpty {
                Text("“\(word.example)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            }
            HStack {
                Text("Reviews \(word.reviewCount)")
                if let next = word.nextReview { Text("Next \(next)") }
                if !word.createdAt.isEmpty { Text("Added \(word.createdAt)") }
                Spacer()
                Picker("", selection: Binding(
                    get: { word.status },
                    set: { model.setStatus(word, to: $0) }
                )) {
                    Text("new").tag("new")
                    Text("learning").tag("learning")
                    Text("mastered").tag("mastered")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 180)
                Button {
                    model.delete(word)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let color: Color = status == "mastered" ? .green : status == "learning" ? .orange : .secondary
        return Text(status.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Filter bar + pagination

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search vocabulary or meaning", text: Binding(
                get: { model.search },
                set: { model.search = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            Divider().frame(height: 14)
            Picker("Type", selection: Binding(
                get: { model.entryTypeFilter },
                set: { model.entryTypeFilter = $0 }
            )) {
                Text("All types").tag("all")
                Text("Word").tag("word")
                Text("Phrase").tag("phrase")
                Text("Pattern").tag("pattern")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            Picker("Status", selection: Binding(
                get: { model.statusFilter },
                set: { model.statusFilter = $0 }
            )) {
                Text("All (\(model.total))").tag("all")
                Text("New (\(model.counts["new"] ?? 0))").tag("new")
                Text("Learning (\(model.counts["learning"] ?? 0))").tag("learning")
                Text("Mastered (\(model.counts["mastered"] ?? 0))").tag("mastered")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35))
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Button("Prev") {
                guard model.safePage > 1 else { return }
                model.expandedId = nil
                model.page = model.safePage - 1
            }
            .disabled(model.safePage <= 1)
            Text("\(model.safePage) / \(model.totalPages)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48)
            Button("Next") {
                guard model.safePage < model.totalPages else { return }
                model.expandedId = nil
                model.page = model.safePage + 1
            }
            .disabled(model.safePage >= model.totalPages)
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
    }
}

// MARK: - Review

enum ReviewMode: Equatable { case flashcard, typing }

@MainActor
@Observable
final class ReviewModel {
    var current: LexiWord?
    var revealed = false
    var dueCount = 0
    var index = 0
    var mode = ReviewMode.flashcard

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
        index += 1
        next()
    }
}

struct ReviewPane: View {
    @State private var model = ReviewModel()

    var body: some View {
        Group {
            if let word = model.current {
                VStack(spacing: 20) {
                    HStack {
                        Text("\(model.index + 1) / \(model.dueCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 80)
                        Spacer()
                        Picker("Mode", selection: $model.mode) {
                            Text("Flashcard").tag(ReviewMode.flashcard)
                            Text("Type").tag(ReviewMode.typing)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 180)
                    }
                    .padding(.horizontal, 16)

                    if model.mode == .flashcard {
                        VStack(spacing: 10) {
                            Text(word.word)
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                            if !word.pos.isEmpty {
                                Text(word.pos)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                            if model.revealed {
                                MarkdownText(content: word.translation, compact: true)
                                    .frame(maxWidth: 480)
                            } else {
                                Text("Tap to reveal")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .contentShape(Rectangle())
                        .onTapGesture { model.revealed.toggle() }

                        if model.revealed {
                            VStack(alignment: .leading, spacing: 8) {
                                if !word.definition.isEmpty {
                                    MarkdownText(content: word.definition, compact: true)
                                        .opacity(0.85)
                                }
                                if !word.example.isEmpty {
                                    Text("“\(word.example)”")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                                }
                                if !word.note.isEmpty {
                                    MarkdownText(content: word.note, compact: true)
                                        .opacity(0.8)
                                }
                            }
                            .frame(maxWidth: 480)
                            .padding(.horizontal, 16)
                            gradeButtons
                        }
                    } else {
                        // Typing mode: type the word from its meaning, then grade.
                        TypingChallengeView(word: word) {
                            model.next()
                        }
                        .frame(maxWidth: 520)
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

// MARK: - Typing challenge (ReviewPage typing mode parity)

/// Shows the translation/definition; the user types the word. Correct +
/// Enter (or auto-match) grades "good"; Skip grades "again".
struct TypingChallengeView: View {
    let word: LexiWord
    let onDone: () -> Void

    @State private var input = ""

    private var meaning: String {
        [word.translation, word.definition]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var normalizedTarget: String {
        word.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var normalizedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        VStack(spacing: 16) {
            MarkdownText(content: meaning, compact: false)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Type the word…", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16, design: .monospaced))
                .multilineTextAlignment(.center)
                .onSubmit { submit() }
                .onChange(of: input) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTarget {
                        submit()
                    }
                }

            HStack(spacing: 12) {
                Button("Skip (Again)") {
                    LexiStore.applyReviewGrade(id: word.id, rating: "again")
                    onDone()
                }
                .controlSize(.small)
            }
        }
        .padding()
    }

    private func submit() {
        let correct = normalizedInput == normalizedTarget
        LexiStore.applyReviewGrade(id: word.id, rating: correct ? "good" : "again")
        onDone()
    }
}
