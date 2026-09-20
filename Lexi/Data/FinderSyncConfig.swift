import Foundation

/// Finder 右键扩展的共享配置 —— 单一事实源是 App Group 容器里的 JSON，
/// 宿主（设置面板）与沙盒 appex 各自直接读写；appex 在每次 menu(for:)
/// 现读，改动即时生效，无需重启 Finder。
///
/// 此文件同时编入两个二进制（build.sh 的主源集 find 收集 + appex 编译
/// 显式加入）——只依赖 Foundation，勿引入其他模块。
struct FinderSyncConfig: Codable {
    var copyPath = true
    var newFile = true
    var openInTerminal = true
    var openInEditor = true
    /// 新建文件子菜单的扩展名（小写、无点），设置页可编辑。
    var newFileExts = ["txt", "md"]
    var terminalBundleId = "com.apple.Terminal"
    var editorBundleId = "com.apple.TextEdit"

    static let groupID = "group.com.lexi.shared"

    /// 沙盒 appex 走 entitlement 换取的容器 URL；非沙盒宿主没有该
    /// entitlement，containerURL 返回 nil，退回字面路径（同一物理目录）。
    static var sharedContainer: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(groupID)")
    }

    static var fileURL: URL {
        sharedContainer.appendingPathComponent("FinderSyncConfig.json")
    }

    static func load() -> FinderSyncConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return FinderSyncConfig()
        }
        return decoded
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.sharedContainer, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
