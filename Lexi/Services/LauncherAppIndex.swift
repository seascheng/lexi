import AppKit

/// One installed application in the launcher's search index.
struct IndexedApp: Hashable {
    let path: String
    /// Display name — localized `CFBundleDisplayName` when the bundle
    /// carries one, else the disk name. Never includes ".app".
    let name: String
    let bundleID: String?
    /// Lowercased searchable names: display name + disk name (a renamed
    /// copy must still be findable by what Finder shows).
    let matchNames: [String]
}

/// Which apps this Mac actually uses (tinycast `LauncherRankingStore`
/// role, scoped down): every app activation is observed and recorded to
/// UserDefaults, and the launcher's ranking boosts running apps, then
/// recently used ones, above equal matches.
final class AppUsage {
    static let shared = AppUsage()
    private static let storeKey = "launcher.appUsage"

    struct Record: Codable { var count: Int; var lastAt: Double }

    private var records: [String: Record] = [:]  // bundleID → record
    private var observer: Any?
    private var lastPersistAt: Double = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
            let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        {
            records = decoded
        }
    }

    /// Observe activations for the process lifetime; call once at launch.
    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                let id = app.bundleIdentifier,
                id != Bundle.main.bundleIdentifier
            else { return }
            self?.record(id)
        }
    }

    func record(_ bundleID: String, at date: Date = Date()) {
        var rec = records[bundleID] ?? Record(count: 0, lastAt: 0)
        rec.count += 1
        rec.lastAt = date.timeIntervalSince1970
        records[bundleID] = rec
        // Keep the 64 most recent — an uninstalled app's entry would
        // otherwise live forever.
        if records.count > 64 {
            let stale = records.sorted { $0.value.lastAt < $1.value.lastAt }
                .prefix(records.count - 64)
            for (key, _) in stale { records[key] = nil }
        }
        // App switching is frequent; a UserDefaults write per activation
        // would hammer the disk. Flush at most every 5s.
        let now = date.timeIntervalSince1970
        if now - lastPersistAt > 5 {
            lastPersistAt = now
            persist()
        }
    }

    func lastUsed(_ bundleID: String) -> Double? {
        records[bundleID]?.lastAt
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

/// Background index of every installed application (tinycast
/// `SearchScopes`/`AppIndex` parity): default domain scan, one folder
/// level deep, `.app` as a leaf, dedup by bundle id with user domains
/// winning over system ones, and an icon cache.
///
/// Scanned once per process — `ensureScanned` is idempotent; the first
/// `onDone` (main queue) is when the index is queryable. The apps array
/// is written exactly once on the main queue and only read there.
final class LauncherAppIndex {
    static let shared = LauncherAppIndex()

    /// Scan order = dedup priority: user-installed apps beat system apps.
    private static let domains = [
        "/Applications",
        "~/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        // Cryptex-delivered system apps; the /Applications Safari is a
        // hidden symlink.
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
    ]

    /// The helper itself has nothing to launch.
    private static let excludedBundleID = "com.lexi.selection-helper"

    private let queue = DispatchQueue(label: "lexi.launcher.appindex", qos: .utility)
    private let iconCache = NSCache<NSString, NSImage>()
    private var apps: [IndexedApp] = []
    private var didScan = false

    private init() {
        iconCache.countLimit = 256
    }

    /// Kicks the one-time scan. `onDone` fires on the main queue when
    /// the index is ready (only the first scan calls it).
    func ensureScanned(onDone: (() -> Void)? = nil) {
        let done = onDone
        queue.async { [weak self] in
            guard let self, !self.didScan else {
                if let done { DispatchQueue.main.async(execute: done) }
                return
            }
            self.didScan = true
            let found = Self.scan()
            DispatchQueue.main.async {
                self.apps = found
                done?()
            }
        }
    }

    /// Linear scan — the index is a few hundred entries and the panel
    /// asks once per keystroke.
    func results(matching query: String) -> [IndexedApp] {
        guard !query.isEmpty else { return [] }
        return apps.filter { app in
            app.matchNames.contains { $0.contains(query) }
                || app.path.lowercased().contains(query)
        }
    }

    /// The workspace icon for a path — an app bundle or any file's type
    /// icon (Finder's own) — cached by path.
    func icon(forPath path: String) -> NSImage {
        if let cached = iconCache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 24, height: 24)
        iconCache.setObject(icon, forKey: path as NSString)
        return icon
    }

    // MARK: scan

    /// Every `.app` under the default domains, one subfolder deep.
    private static func appBundles() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for domain in domains {
            let url = URL(fileURLWithPath: (domain as NSString).expandingTildeInPath)
            result.append(contentsOf: appBundles(under: url, subfolderDepth: 1, fm: fm))
        }
        return result
    }

    /// `.app` is a leaf here — never descended into, only real
    /// subfolders recurse.
    private static func appBundles(under url: URL, subfolderDepth: Int, fm: FileManager) -> [URL] {
        guard
            let items = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        else { return [] }
        var result: [URL] = []
        for item in items {
            if item.pathExtension == "app" {
                result.append(item)
            } else if subfolderDepth > 0,
                (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            {
                result.append(contentsOf: appBundles(under: item, subfolderDepth: subfolderDepth - 1, fm: fm))
            }
        }
        return result
    }

    private static func scan() -> [IndexedApp] {
        let languages = indexedLanguages
        var byBundleID = Set<String>()
        var result: [IndexedApp] = []
        for url in appBundles() {
            let bundle = Bundle(url: url)
            let bundleID = bundle?.bundleIdentifier
            // Dedup by bundle id; the first (highest-priority) domain wins.
            if let bundleID {
                guard bundleID != excludedBundleID, !byBundleID.contains(bundleID) else { continue }
                byBundleID.insert(bundleID)
            }
            let diskName = url.deletingPathExtension().lastPathComponent
            // `object(forInfoDictionaryKey:` consults lproj InfoPlist.strings
            // — but Apple's own apps keep localized names in
            // InfoPlist.loctable, which that path misses entirely (why
            // "监" never found 活动监视器). `localizedNames` reads both.
            let declared = nonBlank(bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? nonBlank(bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            let localized = localizedNames(for: url, languages: languages)
            // Finder parity: the preferred-language name is the label.
            let name = localized.first ?? declared ?? diskName
            let matchNames = localized + [declared].compactMap { $0 } + [diskName, name]
            result.append(IndexedApp(
                path: url.path,
                name: name,
                bundleID: bundleID,
                matchNames: Array(Set(matchNames.map { $0.lowercased() })).sorted()
            ))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: localized names (tinycast BundleLocalization parity)

    /// Preferred languages first, English last: a user who reads Chinese
    /// still finds apps by their English name.
    private static let indexedLanguages: [String] = {
        var codes: [String] = []
        var seen = Set<String>()
        for tag in Locale.preferredLanguages + ["en"] {
            let bare = tag.split(separator: "-").first.map(String.init) ?? tag
            for form in [tag, regionForm(tag), bare].compactMap({ $0 }) {
                // loctable keys and .lproj folders use underscores where a
                // language tag uses "-".
                let underscored = form.replacingOccurrences(of: "-", with: "_")
                for code in [form, underscored]
                where !code.isEmpty && seen.insert(code).inserted {
                    codes.append(code)
                }
            }
        }
        return codes
    }()

    /// Apple keys a script-bearing tag by region alone, so a `zh-Hans-CN`
    /// Mac wants the `zh_CN` loctable key.
    private static func regionForm(_ tag: String) -> String? {
        let subtags = tag.split(separator: "-")
        guard subtags.contains(where: { $0.count == 4 && $0.allSatisfy(\.isLetter) })
        else { return nil }
        let language = Locale.Language(identifier: tag)
        guard let code = language.languageCode?.identifier,
            let region = language.region
                ?? Locale.Language(identifier: language.maximalIdentifier).region
        else { return nil }
        return "\(code)-\(region.identifier)"
    }

    /// Every localized display name the bundle carries in the indexed
    /// languages, most preferred first — loctable first, then classic
    /// `<lang>.lproj/InfoPlist.strings`.
    private static func localizedNames(for bundleURL: URL, languages: [String]) -> [String] {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let table = plist(at: resources.appendingPathComponent("InfoPlist.loctable"))
        var result: [String] = []
        var seen = Set<String>()
        for code in languages {
            let strings = plist(at: resources.appendingPathComponent("\(code).lproj/InfoPlist.strings"))
            for source in [table?[code] as? [String: Any], strings] {
                guard let source,
                    let name = nonBlank(source["CFBundleDisplayName"] as? String)
                        ?? nonBlank(source["CFBundleName"] as? String),
                    seen.insert(name.lowercased()).inserted
                else { continue }
                result.append(name)
            }
        }
        return result
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil))
            as? [String: Any]
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
