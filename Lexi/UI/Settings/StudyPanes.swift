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
        total = counts.values.reduce(0, +)
        let filtered = status.map { counts[$0] ?? 0 } ?? total
        total = status == nil ? total : filtered
        let offset = (safePage - 1) * pageSize
        rows = LexiStore.words(search: search, status: status, offset: offset, limit: pageSize)
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
        Group {
            if model.rows.isEmpty {
                ContentUnavailableView(
                    "No matching entries",
                    systemImage: "book",
                    description: Text("Select a word anywhere and run Translate — single words save automatically.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    filterBar
                    List {
                        ForEach(model.rows) { word in
                            wordRow(word)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    paginationBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Collapsed row + expanded detail (React parity)

    private func wordRow(_ word: LexiWord) -> some View {
        // Manual disclosure row: DisclosureGroup's system chevron sits
        // high against custom label heights — everything here shares one
        // centered HStack instead.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    model.toggleExpand(word)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(model.expandedId == word.id ? 90 : 0))
                        Text(word.word)
                            .lineLimit(1)
                        if !word.translation.isEmpty {
                            MarkdownText(content: word.translation, compact: true, inline: true)
                                .frame(height: 18, alignment: .center)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(word.status.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    model.delete(word)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Delete entry")
            }
            .frame(height: 24, alignment: .center)
            .padding(.vertical, 4)

            if model.expandedId == word.id {
                expandedDetail(word)
            }
        }
    }

    /// Review-pane-style markdown block, then the meta line and the status
    /// picker on their own rows so nothing overlaps.
    private func expandedDetail(_ word: LexiWord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if !word.note.isEmpty {
                    MarkdownText(content: word.note, compact: true)
                } else {
                    if !word.pos.isEmpty {
                        Text(word.pos)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    if !word.translation.isEmpty {
                        MarkdownText(content: word.translation, compact: true)
                    }
                    if !word.definition.isEmpty {
                        MarkdownText(content: word.definition, compact: true)
                    }
                }
                if !word.example.isEmpty {
                    Text("“\(word.example)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)

            Text([word.reviewCount > 0 ? "Reviews \(word.reviewCount)" : nil,
                  word.nextReview.map { "Next \($0)" },
                  word.createdAt.isEmpty ? nil : "Added \(word.createdAt)"]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Picker("Status", selection: Binding(
                    get: { word.status },
                    set: { model.setStatus(word, to: $0) }
                )) {
                    Text("new").tag("new")
                    Text("learning").tag("learning")
                    Text("mastered").tag("mastered")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Filter bar + pagination

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("Search vocabulary or meaning", text: Binding(
                get: { model.search },
                set: { model.search = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 220)
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
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Button("Prev") {
                guard model.safePage > 1 else { return }
                model.expandedId = nil
                model.page = model.safePage - 1
            }
            .disabled(model.safePage <= 1)
            Spacer()
            Text("\(model.safePage) / \(model.totalPages)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(minWidth: 48)
            Spacer()
            Button("Next") {
                guard model.safePage < model.totalPages else { return }
                model.expandedId = nil
                model.page = model.safePage + 1
            }
            .disabled(model.safePage >= model.totalPages)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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

    /// Typing-mode grade: persists the rating but keeps the counter on the
    /// flashcard-only `index` (typing rounds are bonus reps, not counted).
    func gradeTyping(correct: Bool) {
        guard let word = current else { return }
        LexiStore.applyReviewGrade(id: word.id, rating: correct ? "good" : "again")
    }

    func grade(_ rating: String) {
        guard let word = current else { return }
        LexiStore.applyReviewGrade(id: word.id, rating: rating)
        index += 1
        next()
    }
}

struct ReviewPane: View {
    /// Probe-only: the next pane instance starts revealed (synthetic
    /// clicks never reach SwiftUI tap gestures).
    static var debugRevealNext = false

    @State private var model: ReviewModel

    init() {
        let seeded = ReviewModel()
        if Self.debugRevealNext {
            seeded.revealed = true
            Self.debugRevealNext = false
        }
        _model = State(initialValue: seeded)
    }

    var body: some View {
        Group {
            if let word = model.current {
                VStack(spacing: 20) {
                    HStack(spacing: 16) {
                        Text("\(model.index + 1) / \(model.dueCount)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Picker("Mode", selection: $model.mode) {
                            Text("Flashcard").tag(ReviewMode.flashcard)
                            Text("Type").tag(ReviewMode.typing)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    .frame(maxWidth: 520)

                    if model.mode == .flashcard {
                        VStack(spacing: 10) {
                            Text(word.word)
                                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            if !word.pos.isEmpty {
                                Text(word.pos)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                            if model.revealed {
                                MarkdownText(content: word.translation, compact: true)
                                    .frame(maxWidth: 520)
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
                            // One card column: capped width, centered —
                            // matches the header bar's 520pt column so the
                            // revealed block reads as one centered card.
                            VStack(alignment: .leading, spacing: 8) {
                                if !word.definition.isEmpty {
                                    MarkdownText(content: word.definition, compact: true)
                                        .opacity(0.85)
                                }
                                if !word.example.isEmpty {
                                    Text("“\(word.example)”")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                if !word.note.isEmpty {
                                    MarkdownText(content: word.note, compact: true)
                                        .opacity(0.8)
                                }
                            }
                            .frame(maxWidth: 520, alignment: .leading)
                            gradeButtons
                        }
                    } else {
                        // Typing mode: type the word from its meaning, then grade.
                        TypingChallengeView(word: word, onGrade: { model.gradeTyping(correct: $0) }) {
                            model.next()
                        }
                        .frame(maxWidth: 520)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            ForEach([
                ("again", "Again", "arrow.counterclockwise", Color.red),
                ("hard", "Hard", "hand.thumbsdown", Color.orange),
                ("good", "Good", "checkmark", Color.blue),
                ("easy", "Easy", "checkmark.circle.fill", Color.green),
            ], id: \.0) { rating, label, symbol, color in
                Button {
                    model.grade(rating)
                } label: {
                    Label(label, systemImage: symbol)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
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
    let onGrade: (Bool) -> Void
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
                .frame(maxWidth: 520)

            TextField("Type the word…", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .multilineTextAlignment(.center)
                .onSubmit { submit() }
                .onChange(of: input) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTarget {
                        submit()
                    }
                }

            HStack(spacing: 12) {
                Button("Skip (Again)") {
                    onGrade(false)
                    onDone()
                }
                .controlSize(.small)
            }
        }
        .padding()
    }

    private func submit() {
        let correct = normalizedInput == normalizedTarget
        onGrade(correct)
        onDone()
    }
}
