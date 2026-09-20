// LexiFinderSync — Finder 右键菜单扩展（FinderSync.appex）
//
// 独立编译单元：不引用主程序任何源码（App/Design/UI/…），构建脚本
// 单独 swiftc 编出二进制，装配为 LexiSelectionHelper.app/Contents/PlugIns/
// 下的 .appex。所有动作在本进程内完成，与主程序零 IPC。
//
import Cocoa
import FinderSync
import os

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        log("extension loaded")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        log("menu requested kind=\(menuKind.rawValue)")
        // Only Finder's right-click menus (items/container/sidebar).
        guard menuKind != .toolbarItemMenu else { return NSMenu() }
        let config = FinderSyncConfig.load()
        let menu = NSMenu(title: "Lexi")

        if config.copyPath {
            menu.addItem(item("复制路径", action: #selector(copyPaths(_:))))
        }
        if config.newFile {
            let newFile = item("新建文件", action: nil)
            let sub = NSMenu()
            for ext in config.newFileExts.filter({ !$0.isEmpty }) {
                let child = item("未命名.\(ext)", action: #selector(newFile(_:)))
                child.keyEquivalent = ""
                child.representedObject = ext
                sub.addItem(child)
            }
            if sub.items.isEmpty { return menu }
            newFile.submenu = sub
            menu.addItem(newFile)
        }
        if config.openInTerminal {
            menu.addItem(item("在终端打开", action: #selector(openInTerminal(_:))))
        }
        if config.openInEditor {
            menu.addItem(item("用编辑器打开", action: #selector(openInEditor(_:))))
        }
        return menu
    }

    // MARK: - Actions

    @objc private func copyPaths(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        putPasteboard(urls.map(\.path).joined(separator: "\n"))
        log("copy paths: \(urls.count) item(s)")
    }


    /// representedObject = 扩展名（"txt" / "md"）
    @objc private func newFile(_ sender: NSMenuItem) {
        let ext = (sender.representedObject as? String) ?? "txt"
        guard let dir = FIFinderSyncController.default().targetedURL() else {
            log("new file: no targetedURL")
            return
        }
        var name = "未命名.\(ext)"
        var path = dir.appendingPathComponent(name).path
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            name = "未命名 \(n).\(ext)"
            path = dir.appendingPathComponent(name).path
            n += 1
        }
        guard FileManager.default.createFile(atPath: path, contents: Data()) else {
            log("new file: create failed at \(path)")
            return
        }
        log("new file: \(path)")
    }

    @objc private func openInTerminal(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return }
        let dirs = Set(urls.map { url -> URL in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir ? url : url.deletingLastPathComponent()
        })
        openWithApp(dirs, preferred: FinderSyncConfig.load().terminalBundleId,
                    fallback: "com.apple.Terminal", what: "terminal")
    }

    @objc private func openInEditor(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        openWithApp(Set(urls), preferred: FinderSyncConfig.load().editorBundleId,
                    fallback: "com.apple.TextEdit", what: "editor")
    }

    private func openWithApp(
        _ urls: Set<URL>, preferred: String, fallback: String, what: String
    ) {
        guard !urls.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let app = workspace.urlForApplication(withBundleIdentifier: preferred)
            ?? workspace.urlForApplication(withBundleIdentifier: fallback)
        guard let app else {
            log("\(what) app not found (\(preferred) / \(fallback))")
            return
        }
        for url in urls {
            workspace.open([url], withApplicationAt: app,
                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { log("\(what) open failed: \(error.localizedDescription)") }
            }
        }
        log("open with \(what) \(app.lastPathComponent): \(urls)")
    }

    // MARK: - Helpers

    private func item(_ title: String, action: Selector?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.image = Self.logoImage
        return it
    }

    /// 全部菜单项统一使用 Lexi 标记（HapiGo 式来源标识）。加载 bundle 内
    /// 的 LexiLogo.svg、按 2x 栅格化成位图并设 isTemplate —— Finder 注入
    /// 菜单的遗留绘制管线只对位图做模板遮罩。进程内缓存一次。
    static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "LexiLogo", withExtension: "svg"),
              let svg = NSImage(contentsOfFile: url.path) else { return nil }
        let size = NSSize(width: 16, height: 16)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        svg.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }()

    private func putPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// 沙盒进程的 /tmp 落在容器内、外部读不到 —— 用统一日志（os_log），
/// 外部以 `log show --predicate 'subsystem == "com.lexi.selection-helper.FinderSync"'` 读取。
private let logger = Logger(subsystem: "com.lexi.selection-helper.FinderSync", category: "menu")

private func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}
