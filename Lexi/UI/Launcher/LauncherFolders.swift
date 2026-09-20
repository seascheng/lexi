import AppKit
import Foundation

/// Tagged-folder discovery (Spotlight `NSMetadataQuery`) and recents
/// persistence for the launcher. Split out of `LauncherPanel.swift`; the
/// `didRequestProtectedAccess` stored property stays on the class
/// declaration (Swift extensions can't hold stored instance properties).
extension LauncherPanelController {

    // MARK: tagged folders (Spotlight metadata)

    /// TCC silently filters Desktop/Documents/Downloads items out of
    /// NSMetadataQuery results for processes without folder permission (why
    /// the first run showed 3 of 17 tagged folders). One listing attempt per
    /// protected folder triggers the system prompt (Info.plist usage
    /// descriptions required); a grant persists for the app, and the query
    /// re-runs on the next show (5s throttle).
    func requestProtectedFolderAccessIfNeeded() {
        guard !didRequestProtectedAccess else { return }
        didRequestProtectedAccess = true
        // Off the main thread: the TCC prompt BLOCKS the listing call until
        // answered, and show() must never freeze behind a dialog the user
        // may not notice. One prompt set total; grants persist per app.
        DispatchQueue.global(qos: .utility).async {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            for folder in ["Desktop", "Documents", "Downloads"] {
                _ = try? FileManager.default.contentsOfDirectory(
                    atPath: home.appendingPathComponent(folder).path
                )
            }
        }
    }

    func refreshFoldersData() {
        if let last = lastQueryAt, Date().timeIntervalSince(last) < 5 { return }
        stopMetadataQuery()
        let query = NSMetadataQuery()
        // `== '*'` compiles to a LITERAL match (always empty) — LIKE keeps
        // the wildcard semantics and matches any tagged item (verified:
        // == gives 0 results, LIKE gives 17 on this machine).
        query.predicate = NSPredicate(format: "%K LIKE '*'", "kMDItemUserTags")
        query.searchScopes = [URL(fileURLWithPath: NSHomeDirectory())]
        NotificationCenter.default.addObserver(
            self, selector: #selector(metadataQueryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        query.start()
        metadataQuery = query
        lastQueryAt = Date()
    }

    func stopMetadataQuery() {
        if let query = metadataQuery {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            query.stop()
        }
        metadataQuery = nil
    }

    @objc private func metadataQueryDidFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()
        var items: [FolderItem] = []
        for result in query.results {
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let rawTags = (item.value(forAttribute: "kMDItemUserTags") as? [String]) ?? []
            let tag = rawTags.map(Self.normalizedTag).first ?? ""
            items.append(FolderItem(
                path: path, name: url.lastPathComponent, tag: tag,
                tagIndex: Self.tagColorIndex(path: path, tagName: tag)
            ))
        }
        query.enableUpdates()
        FileLog.write("launcher folders query: raw=\(query.results.count) folders=\(items.count) sample=\(items.prefix(3).map(\.path).joined(separator: " | "))")
        stopMetadataQuery()
        taggedFolders = items.sorted {
            ($0.tag, $0.name.lowercased()) < ($1.tag, $1.name.lowercased())
        }
        // The settings pane lists tags for ordering/disabling — publish
        // the known set whenever it changes (Spotlight is the source).
        let known = Array(Set(taggedFolders.map(\.tag))).sorted()
        if known != LexiStore.tagList("launcher.knownTags") {
            LexiStore.saveTagList(known, for: "launcher.knownTags")
        }
        if panel.isVisible { reload() }
    }

    /// Finder writes the 7 default color tags with a leading symbol scalar
    /// (e.g. "🔴红色") — strip leading symbol/emoji scalars, keep the name.
    static func normalizedTag(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.drop { scalar in
            scalar.value >= 0x1F000 || (scalar.value >= 0x2190 && scalar.value <= 0x2BFF)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// The Finder color slot (1-7) for a tag, from the folder's raw
    /// `com.apple.metadata:_kMDItemUserTags` xattr. On disk each entry is
    /// "Name\nN"; Spotlight strips the "\nN", which is why the panel used
    /// to show hash colors instead of the Finder ones. 0 = no color /
    /// unreadable. The entry matching `tagName` wins (multi-tag folders);
    /// otherwise the first entry (Finder's primary dot).
    static func tagColorIndex(path: String, tagName: String) -> Int {
        let xattr = "com.apple.metadata:_kMDItemUserTags"
        let needed = getxattr(path, xattr, nil, 0, 0, 0)
        guard needed > 0 else { return 0 }
        var buffer = Data(count: needed)
        let read = buffer.withUnsafeMutableBytes { pointer in
            getxattr(path, xattr, pointer.baseAddress, needed, 0, 0)
        }
        guard read > 0,
              let plist = try? PropertyListSerialization.propertyList(
                  from: buffer.prefix(read), options: [], format: nil),
              let entries = plist as? [String]
        else { return 0 }
        let parsed = entries.compactMap { entry -> (String, Int)? in
            let parts = entry.split(separator: "\n", omittingEmptySubsequences: false)
            guard parts.count == 2, let index = Int(parts[1]), (1...7).contains(index) else { return nil }
            return (normalizedTag(String(parts[0])), index)
        }
        return parsed.first { $0.0 == tagName }?.1
            ?? parsed.first?.1
            ?? 0
    }

    // MARK: recents (helper-local persistence)

    static func loadRecents() -> [RecentItem] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let items = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return [] }
        return items.sorted { $0.lastAt > $1.lastAt }
    }

    func persistRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    /// Record an open attempt. A failing path is not re-inserted; after 3
    /// failures the entry is dropped entirely (spec §7).
    func recordOpen(path: String, ok: Bool) {
        let previous = recents.first { $0.path == path }
        recents.removeAll { $0.path == path }
        if ok {
            recents.insert(
                RecentItem(path: path, count: (previous?.count ?? 0) + 1, lastAt: Date().timeIntervalSince1970),
                at: 0
            )
            openFailures[path] = nil
        } else {
            let failures = (openFailures[path] ?? 0) + 1
            if failures >= 3 {
                openFailures[path] = nil
            } else {
                openFailures[path] = failures
            }
        }
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        persistRecents()
    }
}
