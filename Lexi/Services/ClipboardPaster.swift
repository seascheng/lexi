import AppKit

/// Paste-back (tinycast Paster contract): write the item's flavors plus the
/// internal marker so the poller skips our own write, activate the app that
/// was frontmost before the panel, then synthesize the full ⌘V sequence from
/// a combinedSessionState source. The pasted item BECOMES the clipboard —
/// standard clipboard-manager semantics, no restore lease here.
enum ClipboardPaster {
    /// Covers the gap between `activate()` returning and the target app
    /// accepting a keystroke (tinycast activationDelay).
    private static let activationDelay: TimeInterval = 0.08

    /// Off-main queue for the (possibly multi-MB) image blob read in
    /// `paste` — text/file writes stay synchronous.
    private static let pasteQueue = DispatchQueue(label: "com.lexi.clipboard.paste", qos: .userInitiated)

    /// LaunchServices activation — `NSRunningApplication.activate()` is
    /// silently ignored for background (.accessory) callers on macOS 14+
    /// (same bug the launcher fixed in de2910d): the paste then landed in
    /// whatever held key focus (the result card's input bar). The paste is
    /// posted from the activation completion — a fixed delay raced the
    /// async LS roundtrip.
    private static func activateThenPaste(_ app: NSRunningApplication?) {
        // Computed once; every branch below calls this same continuation
        // instead of repeating the asyncAfter/postCommandV pair three times.
        let continuePaste = {
            DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
                postCommandV()
            }
        }
        guard let app else {
            continuePaste()
            return
        }
        // Launcher recipe (de2910d/dd074da): a BACKGROUND app's activation
        // requests are ignored — make ourselves the active app first, then
        // LaunchServices honors the target activation.
        NSApp.activate(ignoringOtherApps: true)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let bundleURL = app.bundleURL else {
            continuePaste()
            return
        }
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            continuePaste()
        }
    }

    /// Attempts the pasteboard write first; only on success does it hide/
    /// activate — a failed write (e.g. a vanished file) leaves the caller's
    /// UI untouched. An image write's disk read happens off-main; `paste`
    /// only activates/pastes once that read and the resulting write finish,
    /// preserving write-before-paste ordering.
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?,
        completion: @escaping (Bool) -> Void
    ) {
        guard item.kind == .image, let url = store.imageURL(for: item) else {
            let success = write(item, store: store)
            if success { activateThenPaste(previousApp) }
            completion(success)
            return
        }
        pasteQueue.async {
            let data = try? Data(contentsOf: url)
            DispatchQueue.main.async {
                let success = data.map { write(item, store: store, imageData: $0) } ?? false
                if success { activateThenPaste(previousApp) }
                completion(success)
            }
        }
    }

    /// String counterpart — note rows paste their content the same way. The
    /// internal marker keeps the paste out of history (notes are their own
    /// persistent store; duplicating them as clips would be noise).
    @discardableResult
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) -> Bool {
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, ClipboardMonitor.internalType], owner: nil)
        pb.setString(text, forType: .string)
        activateThenPaste(previousApp)
        return true
    }


    /// Flavor sets by kind — a file carries BOTH `public.file-url` (file
    /// takers receive the file) and `.string` with the PATH (text fields and
    /// terminals want the path; a name is recoverable from a path, a path is
    /// not recoverable from a name). Every write appends the empty internal
    /// marker; the poller then skips it, so `promote` here is the only
    /// history reordering a paste causes. Pinned rows skip promote inside
    /// the store — pasting a pin holds its place.
    ///
    /// Exposed (not private): `paste` calls this directly so a failed write
    /// (e.g. a vanished file) can be detected before any UI changes. When
    /// `imageData` is supplied (the off-main-read path in `paste`) it is
    /// used instead of re-reading the file.
    @discardableResult
    static func write(_ item: ClipboardItem, store: ClipboardStore, imageData: Data? = nil) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pb.declareTypes([.string, ClipboardMonitor.internalType], owner: nil)
            pb.setString(text, forType: .string)
        case .image:
            guard let data = imageData ?? store.imageURL(for: item).flatMap({ try? Data(contentsOf: $0) }) else {
                return false
            }
            pb.declareTypes([.png, ClipboardMonitor.internalType], owner: nil)
            pb.setData(data, forType: .png)
        case .file:
            guard let path = item.filePath,
                  FileManager.default.fileExists(atPath: path)
            else { return false }
            let url = URL(fileURLWithPath: path)
            pb.declareTypes([.fileURL, .string, ClipboardMonitor.internalType], owner: nil)
            pb.setData(url.dataRepresentation, forType: .fileURL)
            pb.setString(url.path, forType: .string)
        }
        store.promote(item)
        return true
    }

    /// Combined-session source + command flag on the down event: Chromium
    /// hosts ignore pid-posted synthetic keys, session-tap events ride the
    /// normal dispatch path and are honored like real ones.
    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        // The down/up gap was a blocking usleep on main; posted from a
        // delayed main-queue block instead so main never stalls.
        up.flags = .maskCommand
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            up.post(tap: .cghidEventTap)
        }
    }
}
