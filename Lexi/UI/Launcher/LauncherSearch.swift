import AppKit
import Foundation

/// Search/filter pipeline for the launcher: query-driven reload, debounced
/// Spotlight file search, the folder grid builder, and the unified
/// (folders + apps + calculator) result-list builder. Split out of
/// `LauncherPanel.swift` — the class declaration, chrome, and keyboard/
/// table plumbing stay there.
extension LauncherPanelController {

    // MARK: data

    func reload() {
        refreshFoldersData()
        let filter = filterText
        calcValue = filter.isEmpty ? nil : CalcEngine.evaluate(filter)
        rows = filter.isEmpty ? buildFolderRows() : buildSearchRows()
        scheduleFileSearch(for: filter)
        tableView.reloadData()
        if filter.isEmpty {
            // Grid selection lives in `selectedChip`; default to the first
            // chip so Enter works immediately — but a refresh (e.g. the
            // Spotlight query landing ~1s after open) must not snap an
            // existing keyboard selection back to the first chip.
            if let cur = selectedChip,
               rows.indices.contains(cur.row),
               case .chipLine(let chips) = rows[cur.row],
               chips.indices.contains(cur.chip) {
                // keep it
            } else if let first = chipLineRows().first {
                selectedChip = (row: first, chip: 0)
            } else {
                selectedChip = nil
            }
        } else {
            // Result mode selects the first row — the calculator answer
            // when the query is one, so Enter copies it immediately.
            tableView.deselectAll(nil)
            if let first = selectableRowIndexes().first {
                tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            }
        }
        let empty = rows.isEmpty
        emptyLabel.isHidden = !empty
        emptyLabel.stringValue = filter.isEmpty
            ? "No tagged folders — tag folders in Finder to list them here"
            : "No matches"
        placePanel()
    }

    /// Debounced Spotlight fetch (tinycast FileSearchSession parity):
    /// latest-wins per phase, off-main, landing only when the query is
    /// still current. The fast phase (exact+prefix, index-backed) fills
    /// the page for nearly every query; the deep substring scan runs
    /// only when it couldn't.
    func scheduleFileSearch(for filter: String) {
        fileSearchWork?.cancel()
        guard !filter.isEmpty, filter != fileHitsQuery else {
            if filter.isEmpty {
                fileHits = []
                fileHitsQuery = ""
            }
            return
        }
        runFileSearch(.fast, filter: filter) { [weak self] fast in
            guard let self else { return }
            self.fileHits = fast
            self.fileHitsQuery = filter
            self.reloadIfCurrent(filter)
            guard fast.count < FileSearchService.resultLimit else { return }
            self.runFileSearch(.deep, filter: filter) { deep in
                var seen = Set(fast.map(\.url.path))
                self.fileHits = fast + deep.filter { seen.insert($0.url.path).inserted }
                self.reloadIfCurrent(filter)
            }
        }
    }

    private func runFileSearch(
        _ phase: FileSearchService.Phase, filter: String,
        land: @escaping ([FileSearchService.Hit]) -> Void
    ) {
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard !(work?.isCancelled ?? true) else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let hits = FileSearchService.search(filter, phase: phase)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            FileLog.write("LAUNCH filesearch \(phase == .fast ? "fast" : "deep") q=\(filter) hits=\(hits.count) ms=\(ms)")
            DispatchQueue.main.async {
                guard let self, self.filterText == filter, self.panel.isVisible,
                    !(work?.isCancelled ?? true)
                else { return }
                land(hits)
            }
        }
        fileSearchWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reloadIfCurrent(_ filter: String) {
        guard filterText == filter, panel.isVisible else { return }
        reload()
    }

    func selectableRowIndexes() -> [Int] {
        rows.indices.filter { row in
            switch rows[row] {
            case .header: return false
            case .chipLine: return !isSearching
            case .result, .calc: return isSearching
            }
        }
    }

    func chipLineRows() -> [Int] {
        rows.indices.filter { row in
            if case .chipLine = rows[row] { return true }
            return false
        }
    }

    /// Canonical home subfolders pinned to the top of the folder grid
    /// (Favorites → Recent → tag groups). Displayed with the system-
    /// localized name (桌面/下载/…); only folders that exist are listed.
    static let favoriteFolderNames = ["Desktop", "Documents", "Downloads", "Movies", "Pictures"]

    private func buildFolderRows() -> [Row] {
        let filter = filterText
        var out: [Row] = []

        func matches(_ name: String, path: String) -> Bool {
            filter.isEmpty
                || name.lowercased().contains(filter)
                || path.lowercased().contains(filter)
        }

        var favorites: [FolderChip] = []
        var favoritePaths: Set<String> = []
        let showFavorites = LexiStore.settingBool("launcher.showFavorites", default: true)
        for name in Self.favoriteFolderNames where showFavorites {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let localizedName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? name
            guard matches(localizedName, path: url.path) else { continue }
            favorites.append(FolderChip(
                item: FolderItem(path: url.path, name: localizedName, tag: ""),
                kind: .favorite
            ))
            favoritePaths.insert(url.path)
        }
        if !favorites.isEmpty {
            out.append(.header("Favorites", nil))
            out += gridChipLines(favorites).map { .chipLine($0) }
        }

        var recentChips: [FolderChip] = []
        let showRecents = LexiStore.settingBool("launcher.showRecents", default: true)
        for item in recents where showRecents && matches(item.path, path: item.path)
            && !favoritePaths.contains(item.path) {
            // The five fixed home folders live in Favorites forever —
            // repeating them in Recent adds no information.
            let url = URL(fileURLWithPath: item.path)
            recentChips.append(FolderChip(
                item: FolderItem(path: item.path, name: url.lastPathComponent, tag: ""),
                kind: .recent
            ))
        }
        if !recentChips.isEmpty {
            out.append(.header("Recent", nil))
            out += gridChipLines(recentChips).map { .chipLine($0) }
        }

        let matching = LexiStore.settingBool("launcher.showTagged", default: true)
            ? taggedFolders.filter { matches($0.name, path: $0.path) } : []
        let grouped = Dictionary(grouping: matching) { $0.tag.isEmpty ? "Untagged" : $0.tag }
        // Finder color slot per tag group (first folder that carries one).
        var slotByTag: [String: Int] = [:]
        for item in matching where item.tagIndex > 0 {
            if slotByTag[item.tag] == nil { slotByTag[item.tag] = item.tagIndex }
        }
        for tag in Self.orderedTags(present: Array(grouped.keys)) {
            let color = finderTagColor(slotByTag[tag] ?? 0)
                ?? vividTagColor(for: tag, dark: cardTheme.isDark)
            out.append(.header(tag, color))
            let chips = grouped[tag]!
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
                .map { item -> FolderChip in
                    // A folder whose own xattr entry carries no color slot
                    // still wears the tag's color in Finder (resolved by
                    // name) — inherit the group's slot like Finder does.
                    var item = item
                    if item.tagIndex == 0 { item.tagIndex = slotByTag[tag] ?? 0 }
                    return FolderChip(item: item, kind: .tagged)
                }
            out += gridChipLines(chips).map { .chipLine($0) }
        }
        return out
    }

    // MARK: tag sections config (settings KV, edited by the Launcher pane)

    /// Present tags in the saved display order, disabled ones dropped,
    /// unknown tags appended alphabetically (a new Finder tag needs no
    /// settings trip).
    static func orderedTags(present: [String]) -> [String] {
        let disabled = Set(LexiStore.tagList("launcher.disabledTags"))
        let order = LexiStore.tagList("launcher.tagOrder")
        let remaining = present.filter { !disabled.contains($0) && !order.contains($0) }.sorted()
        return order.filter { present.contains($0) && !disabled.contains($0) } + remaining
    }


    /// Fixed-column grid: 4 columns × 146pt at an 8pt gutter (608 total).
    /// Every chip fills its cell — wrapped rows stay column-aligned, gaps
    /// are uniform, and the full width is used. Flow-hugged widths left
    /// ragged columns (HIG: inconsistent spacing destroys grid
    /// perception). Overlong names truncate inside the chip; the full
    /// name rides the chip's tooltip.
    static let gridColumns = 4
    static let gridChipWidth: CGFloat = 146
    static let gridGutter: CGFloat = 8

    func gridChipLines(_ chips: [FolderChip]) -> [[FolderChip]] {
        var lines: [[FolderChip]] = []
        var line: [FolderChip] = []
        for (index, chip) in chips.enumerated() {
            var placed = chip
            placed.x = CGFloat(index % Self.gridColumns) * (Self.gridChipWidth + Self.gridGutter)
            placed.width = Self.gridChipWidth
            line.append(placed)
            if line.count == Self.gridColumns {
                lines.append(line)
                line = []
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    // MARK: unified search (folders + installed apps + calculator)

    /// The result list for a typed query: the calculator answer first,
    /// then one flat list. Relevance tier dominates (exact → prefix →
    /// substring → path); WITHIN a tier the personalization ladder:
    /// running apps, then recently used apps and recently opened folders
    /// (by time, merged), favorite folders, tagged folders, unused apps,
    /// other files.
    private func buildSearchRows() -> [Row] {
        var out: [Row] = []
        if let calcValue {
            out.append(.calc(calcValue))
        }
        let filter = filterText

        // Personalization inputs, resolved once per reload.
        let runningIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let recentFolderAt = Dictionary(
            recents.map { ($0.path, $0.lastAt) }, uniquingKeysWith: { a, _ in a })
        let favoritePaths = Set(
            Self.favoriteFolderNames.map { NSHomeDirectory() + "/" + $0 })

        /// (bucket, recency) — the ladder within a tier.
        func priority(_ kind: ResultItem.Kind) -> (Int, Double) {
            switch kind {
            case .app(let app):
                guard let id = app.bundleID else { return (4, 0) }
                if runningIDs.contains(id) {
                    return (0, AppUsage.shared.lastUsed(id) ?? 0)
                }
                if let last = AppUsage.shared.lastUsed(id) { return (1, last) }
                return (4, 0)
            case .folder(let path):
                if let last = recentFolderAt[path] { return (1, last) }
                if favoritePaths.contains(path) { return (2, 0) }
                return (3, 0)
            case .file:
                return (5, 0)
            }
        }

        struct Scored {
            let item: ResultItem
            let tier: Int
            let bucket: Int
            let recency: Double
            /// A running app outranks everything ("一打开的app优先") — a
            /// substring-matched Chrome browser beats exact-named build
            /// folders, which is what a launcher is for.
            let isRunningApp: Bool
        }
        func score(_ item: ResultItem, tier: Int) -> Scored {
            let (bucket, recency) = priority(item.kind)
            let running: Bool
            if case .app(let app) = item.kind, let id = app.bundleID {
                running = runningIDs.contains(id)
            } else {
                running = false
            }
            return Scored(item: item, tier: tier, bucket: bucket, recency: recency, isRunningApp: running)
        }

        var scored: [Scored] = []
        var seenPaths = Set<String>()
        for folder in folderSearchCandidates() {
            guard let tier = Self.matchTier(
                query: filter, names: [folder.name.lowercased()], path: folder.path)
            else { continue }
            seenPaths.insert(folder.path)
            scored.append(score(ResultItem(
                kind: .folder(path: folder.path),
                title: folder.name,
                subtitle: (folder.path as NSString).deletingLastPathComponent
            ), tier: tier))
        }
        // Spotlight file/folder hits — only the fetch that matches the
        // current query (stale async results never leak in).
        if fileHitsQuery == filter {
            for hit in fileHits where !seenPaths.contains(hit.url.path) {
                seenPaths.insert(hit.url.path)
                scored.append(score(ResultItem(
                    kind: hit.isDirectory ? .folder(path: hit.url.path) : .file(hit.url),
                    title: hit.name,
                    subtitle: (hit.url.path as NSString).deletingLastPathComponent
                ), tier: Self.matchTier(
                    query: filter, names: [hit.name.lowercased()], path: hit.url.path) ?? 3))
            }
        }
        for app in appIndex.results(matching: filter) {
            let tier = Self.matchTier(query: filter, names: app.matchNames, path: app.path) ?? 3
            scored.append(score(ResultItem(
                kind: .app(app),
                title: app.name,
                subtitle: (app.path as NSString).deletingLastPathComponent
            ), tier: tier))
        }
        scored.sort { a, b in
            if a.isRunningApp != b.isRunningApp { return a.isRunningApp }
            if a.tier != b.tier { return a.tier < b.tier }
            if a.bucket != b.bucket { return a.bucket < b.bucket }
            if a.recency != b.recency { return a.recency > b.recency }
            if a.item.kind.isFolder != b.item.kind.isFolder { return a.item.kind.isFolder }
            return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
        }
        out += scored.prefix(20).map { .result($0.item) }
        return out
    }

    /// Every folder the grid knows, flattened and deduped by path
    /// (favorites → recents → tagged — the same pools the grid renders
    /// as sections).
    private func folderSearchCandidates() -> [FolderItem] {
        var seen = Set<String>()
        var out: [FolderItem] = []
        func add(_ item: FolderItem) {
            guard seen.insert(item.path).inserted else { return }
            out.append(item)
        }
        for name in Self.favoriteFolderNames
        where LexiStore.settingBool("launcher.showFavorites", default: true) {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let localizedName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? name
            add(FolderItem(path: url.path, name: localizedName, tag: ""))
        }
        for recent in recents where LexiStore.settingBool("launcher.showRecents", default: true) {
            add(FolderItem(
                path: recent.path,
                name: (recent.path as NSString).lastPathComponent,
                tag: ""
            ))
        }
        let disabledTags = Set(LexiStore.tagList("launcher.disabledTags"))
        if LexiStore.settingBool("launcher.showTagged", default: true) {
            for folder in taggedFolders where !disabledTags.contains(folder.tag) { add(folder) }
        }
        return out
    }

    /// exact → prefix → substring → path-contains, or nil when nothing
    /// matches (names arrive lowercased; the query already is).
    static func matchTier(query: String, names: [String], path: String) -> Int? {
        if names.contains(query) { return 0 }
        if names.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if names.contains(where: { $0.contains(query) }) { return 2 }
        if path.lowercased().contains(query) { return 3 }
        return nil
    }
}
