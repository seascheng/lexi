import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Spotlight (MDQuery) file/folder search for the launcher — tinycast
/// `FileSearchService` parity, scoped down: home + cloud scopes, filename
/// terms, hidden paths and app bundles excluded, folders ranked first.
///
/// Two phases, because a leading-wildcard substring (`*q*`) is a full
/// index scan (~1s on a busy home) while exact/prefix lookups are
/// index-backed (~tens of ms):
///   .fast — exact + prefix name matches; enough to fill the page for
///           almost every query, so it is what the user usually sees.
///   .deep — the substring scan, capped; only asked for when .fast
///           couldn't fill the page. Its cap can't hide the best match
///           because the exact/prefix hits already arrived via .fast.
///
/// Synchronous by design (`kMDQuerySynchronous`): callers run it off the
/// main thread behind the launcher's keystroke debounce.
enum FileSearchService {

    struct Hit: Hashable {
        let url: URL
        let isDirectory: Bool
        var name: String { url.lastPathComponent }
    }

    enum Phase {
        case fast
        case deep
    }

    static let resultLimit = 12
    /// .fast is index-backed, so a generous cap costs little; .deep's cap
    /// is the index-scan budget (tinycast uses 1,000).
    private static let fastCandidateCap = 400
    private static let deepCandidateCap = 2_000

    /// Ranked hits for the phase; empty when the query is blank.
    static func search(_ rawQuery: String, phase: Phase) -> [Hit] {
        let terms = rawQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var folderIsFolder: [String: Bool] = [:]
        var hits: [Hit] = []
        if phase == .fast {
            // Two tiny index lookups rather than one OR — no dependence on
            // Spotlight's boolean-operator support.
            for term in terms {
                hits += run("kMDItemFSName == \"\(escape(term))\"c", cap: fastCandidateCap, folderCache: &folderIsFolder)
                hits += run("kMDItemFSName == \"\(escape(term))*\"c", cap: fastCandidateCap, folderCache: &folderIsFolder)
            }
        } else {
            let expression = terms
                .map { "kMDItemFSName == \"*\(escape($0))*\"cd" }
                .joined(separator: " && ")
            hits += run(expression, cap: deepCandidateCap, folderCache: &folderIsFolder)
        }
        return rank(hits, terms: terms)
    }

    // MARK: query

    /// A typed term is literal, so its wildcards are neutralized along
    /// with the string delimiters (tinycast FileSearchQuery.escape).
    private static func escape(_ term: String) -> String {
        var out = ""
        for ch in term {
            if ["\\", "\"", "*", "?"].contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func run(_ expression: String, cap: Int, folderCache: inout [String: Bool]) -> [Hit] {
        guard let query = MDQueryCreate(nil, expression as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, scopes() as CFArray, 0)
        MDQuerySetMaxCount(query, cap)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }

        var hits: [Hit] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            // Hidden paths and bundle contents keep File Search quiet.
            if isExcluded(path) { continue }
            let contentType = MDItemCopyAttribute(item, kMDItemContentType) as? String ?? ""
            // UTType lookup is a registry hit — cache per search call.
            let isFolder: Bool
            if let cached = folderCache[contentType] {
                isFolder = cached
            } else {
                isFolder = UTType(contentType)?.conforms(to: .folder) == true
                folderCache[contentType] = isFolder
            }
            if UTType(contentType)?.conforms(to: .application) == true { continue }
            hits.append(Hit(url: URL(fileURLWithPath: path), isDirectory: isFolder))
        }
        return hits
    }

    // MARK: ranking

    /// Folders first, then exact → prefix → substring on the name, then
    /// shallower paths (the folder itself beats junk nested inside it),
    /// non-Library paths on a depth tie (support dirs are rarely the
    /// target), then alphabetical. Sort keys are computed once per hit —
    /// per-comparison key derivation is what made ranking 10k items slow.
    private static func rank(_ hits: [Hit], terms: [String]) -> [Hit] {
        let query = terms.joined(separator: " ").lowercased()
        let libraryPrefix = NSHomeDirectory() + "/Library"

        struct Keyed {
            let hit: Hit
            let tier: Int
            let depth: Int
            let isLibrary: Bool
            let foldedName: String
        }
        let keyed = hits.map { hit -> Keyed in
            let folded = hit.name.lowercased()
            let tier = folded == query ? 0 : (folded.hasPrefix(query) ? 1 : (folded.contains(query) ? 2 : 3))
            return Keyed(
                hit: hit,
                tier: tier,
                depth: hit.url.pathComponents.count,
                isLibrary: hit.url.path.hasPrefix(libraryPrefix),
                foldedName: folded
            )
        }
        return keyed
            .sorted { a, b in
                if a.hit.isDirectory != b.hit.isDirectory { return a.hit.isDirectory }
                if a.tier != b.tier { return a.tier < b.tier }
                if a.depth != b.depth { return a.depth < b.depth }
                if a.isLibrary != b.isLibrary { return b.isLibrary }
                return a.foldedName < b.foldedName
            }
            .prefix(resultLimit)
            .map(\.hit)
    }

    // MARK: scopes

    /// Home root plus the cloud mounts — the same surface the tagged-
    /// folders query covers (Desktop/Documents/Downloads items arrive
    /// only after their TCC grant, like every other Spotlight consumer).
    /// Resolved once per call, not per keystroke on the main thread.
    private static func scopes() -> [String] {
        let home = NSHomeDirectory()
        var list = [home]
        let fm = FileManager.default
        for extra in [
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs",
        ] {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: extra, isDirectory: &isDirectory), isDirectory.boolValue {
                list.append(extra)
            }
        }
        return list
    }

    private static func isExcluded(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            (component.hasPrefix(".") && component != "." && component != "..")
                || component.lowercased().hasSuffix(".app")
        }
    }
}
