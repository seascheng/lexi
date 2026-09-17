import AppKit

// Clipboard capture engine — 0.5s poll of NSPasteboard.general.changeCount,
// ported from tinycast's ClipboardManager. Invariants carried over:
//
// - our own writes stamp a private internalType marker so the poller skips
//   them (without it, a paste would re-enter history in a loop);
// - sensitive markers (password managers, browsers, the OS) are skipped
//   UNCONDITIONALLY — before every content branch, whatever the shape;
// - a file URL is read BEFORE the text: Finder puts the file's display name
//   on public.utf8-plain-string beside public.file-url, so a text-first
//   poller records IMG_1234.png as prose;
// - files are referenced where they lie (never copied), volatile roots are
//   rejected, and a Finder select-all cannot insert ten thousand rows on one
//   tick;
// - the pasteboard carries no source, so capture attributes to the
//   frontmost app at poll time (0.5s attribution window, accepted).
//
// Lease mutex: text_injection's tier 3 borrows the pasteboard for a
// synthesized ⌘V. Rust posts /clipboard-suspend before borrowing and
// /clipboard-resume after restoring; a resume whose changeCount still
// matches re-baselines past the lease write, so injected text never lands
// in history.

/// Body of POST /clipboard-suspend and /clipboard-resume.
struct ClipboardLeasePayload: Codable {
    let changeCount: Int64
}

final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    /// Marker we attach when WE write to the pasteboard, so polling ignores
    /// our own writes.
    static let internalType = NSPasteboard.PasteboardType("com.lexi.clipboard.internal")

    /// Longest text captured; bigger copies are skipped.
    static let maxTextLength = 32_000

    /// Markers put on secret copies by password managers, browsers and the OS.
    static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("com.apple.is-sensitive"),
    ]

    /// A Finder select-all must not insert ten thousand rows on one poll tick.
    static let maxCapturedFiles = 32

    /// Reclaimable roots, without the `/private` that `resolvingSymlinksInPath` strips.
    static let volatileRoots = [
        "/tmp/", "/var/tmp/", "/var/folders/",
        NSHomeDirectory() + "/Library/Caches/",
    ]

    /// Images land in the store's images/ dir; icons are cached per bundle id.
    private var store: ClipboardStore?
    private var imagesDir: URL?
    private var iconsDir: URL?
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    /// Non-nil while the injection lease holds the pasteboard.
    private var suspendedFromCount: Int?

    private init() {}

    /// Starts polling. The baseline is the CURRENT changeCount: after a
    /// helper restart we deliberately skip everything copied before it —
    /// only fresh copies enter history.
    func start(store: ClipboardStore) {
        self.store = store
        let fileManager = FileManager.default
        if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("com.lexi.selection-helper", isDirectory: true)
            let icons = dir.appendingPathComponent("icons", isDirectory: true)
            if !fileManager.fileExists(atPath: icons.path) {
                try? fileManager.createDirectory(at: icons, withIntermediateDirectories: true)
            }
            iconsDir = icons
        }
        lastChangeCount = NSPasteboard.general.changeCount
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: lease mutex (called from the TCP thread via the app delegate)

    func suspend(changeCount: Int64) {
        suspendedFromCount = Int(changeCount)
    }

    /// An unchanged changeCount means nothing foreign was written while we
    /// held the pasteboard: re-baseline past the lease write. A changed one
    /// means a genuine copy raced the lease — leave the baseline so the next
    /// poll sees it.
    func resume(changeCount: Int64) {
        guard suspendedFromCount != nil else { return }
        suspendedFromCount = nil
        if NSPasteboard.general.changeCount == Int(changeCount) {
            lastChangeCount = Int(changeCount)
        }
    }

    // MARK: polling

    private func poll() {
        guard let store else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if suspendedFromCount != nil { return }

        if pb.types?.contains(Self.internalType) == true { return }

        // Never record secrets: skip copies tagged sensitive by any of the
        // marker owners — unconditional, before every content branch.
        if let types = pb.types, !types.isEmpty, !Set(types).isDisjoint(with: Self.sensitiveTypes) {
            return
        }

        // The pasteboard carries no source, so attribute it to the frontmost
        // app at poll time.
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Ahead of the text branch: Finder puts the file's *name* on .string
        // beside its URL. Nil (not empty) so a copied http URL falls through
        // and stays a text row.
        if let paths = Self.fileURLs(on: pb) {
            store.addFiles(paths, sourceBundleID: sourceBundleID)
            return
        }

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard text.count <= Self.maxTextLength else { return }
            store.addText(text, sourceBundleID: sourceBundleID)
            return
        }

        if let type = pb.availableType(from: [.png, .tiff]), let data = pb.data(forType: type) {
            let isPNG = type == .png
            // A big TIFF→PNG re-encode can take 100ms+ — keep the poll off
            // that path. The row insert happens on the main actor inside the
            // store's caller context; the encode is what must move away.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let png = isPNG ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                guard let png else { return }
                DispatchQueue.main.async {
                    _ = self?.store?.addImage(png, sourceBundleID: sourceBundleID)
                }
            }
        }
    }

    /// Durable file URLs from every pasteboard item's own `public.file-url`.
    /// Rejects volatile roots (an app that stages a temp export beside better
    /// inline content must keep the inline content) and caps the batch.
    static func fileURLs(on pasteboard: NSPasteboard) -> [String]? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var urls: [String] = []
        for item in items {
            guard let data = item.data(forType: .fileURL),
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            if isDurable(resolved) { urls.append(resolved) }
        }
        let durable = Array(urls.prefix(maxCapturedFiles))
        guard !durable.isEmpty else { return nil }
        return durable.reversed()
    }

    private static func isDurable(_ path: String) -> Bool {
        for root in volatileRoots where path.hasPrefix(root) {
            return false
        }
        return true
    }

    // MARK: source icons

    private var iconCache: [String: NSImage] = [:]

    /// PNG-cached app icon for a source bundle id, rendered once at 72×72.
    /// Unknown bundle ids (uninstalled apps, helper processes) return nil —
    /// the panel draws a generic glyph.
    func cachedIcon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }

        let fileManager = FileManager.default
        if let iconsDir,
           fileManager.fileExists(atPath: iconsDir.appendingPathComponent(bundleID + ".png").path),
           let image = NSImage(contentsOf: iconsDir.appendingPathComponent(bundleID + ".png"))
        {
            iconCache[bundleID] = image
            return image
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 36, height: 36)
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        if let iconsDir {
            try? png.write(to: iconsDir.appendingPathComponent(bundleID + ".png"), options: .atomic)
        }
        iconCache[bundleID] = icon
        return icon
    }
}
