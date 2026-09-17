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

    // MARK: polling

    private func poll() {
        guard let store else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

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

    /// Display size of source icons in panel rows (shared design token).
    static let iconDisplaySize: CGFloat = PanelDesign.rowIconSize
    /// Rendered pixel size of the cached PNG — 4x of the display size, so
    /// the icon stays sharp on retina and downscaled gracefully elsewhere.
    private static let iconPixelSize = 96

    private var iconCache: [String: NSImage] = [:]

    /// PNG-cached app icon for a source bundle id. The blur before came from
    /// snapshotting NSWorkspace's icon at 36pt via tiffRepresentation — the
    /// bitmap that exists there is 32px, which a 2x display then upscales.
    /// Rendered now into a real 96px bitmap; NSWorkspace's multi-representation
    /// image downsamples from its 128px rep, so the result is crisp.
    func cachedIcon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }

        let fileManager = FileManager.default
        let cachePath = iconsDir?.appendingPathComponent(bundleID + ".png")
        if let cachePath, fileManager.fileExists(atPath: cachePath.path),
           let image = Self.displayImage(fromPNG: NSImage(contentsOf: cachePath)) {
            iconCache[bundleID] = image
            return image
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let png = Self.renderedIconPNG(forAppAt: appURL)
        else { return nil }
        if let iconsDir {
            try? png.write(to: iconsDir.appendingPathComponent(bundleID + ".png"), options: .atomic)
        }
        guard let image = Self.displayImage(fromPNG: NSImage(data: png)) else { return nil }
        iconCache[bundleID] = image
        return image
    }

    /// Draws the app icon into a plain 96px bitmap (not a tiff snapshot of
    /// whatever representation came back) and encodes it as PNG.
    private static func renderedIconPNG(forAppAt appURL: URL) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let pixels = iconPixelSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Wraps a cached PNG as a display image sized `iconDisplaySize` points.
    private static func displayImage(fromPNG png: NSImage?) -> NSImage? {
        guard let png else { return nil }
        png.size = NSSize(width: iconDisplaySize, height: iconDisplaySize)
        return png
    }
}
