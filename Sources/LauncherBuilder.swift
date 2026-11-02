import AppKit
import CoreServices

enum BuildError: LocalizedError {
    case invalidTimeZone(String)
    case unsupportedBrowser(String)
    case exists(String)
    case icon(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidTimeZone(let tz): return "无效的时区:\(tz)"
        case .unsupportedBrowser(let why): return why
        case .exists(let name): return "已存在同名快捷方式「\(name)」"
        case .icon(let msg): return "生成图标失败:\(msg)"
        case .io(let msg): return msg
        }
    }
}

struct LauncherOptions {
    var timeZoneID: String
    var badge: String
    var badgeColor: NSColor = .defaultBadge
    var blockClaude: Bool = true
    var customName: String? = nil
    var dataDir: URL? = nil
    var replace: Bool = false
    var addDefaultCompanion: Bool = true
}

enum LauncherBuilder {
    /// 浏览器快捷方式里屏蔽的域名(含所有子域名)
    static let blockedHosts = ["claude.ai", "claude.com", "anthropic.com"]

    static var hostRules: String {
        blockedHosts.flatMap { ["MAP \($0) ~NOTFOUND", "MAP *.\($0) ~NOTFOUND"] }.joined(separator: ", ")
    }

    @discardableResult
    static func build(for app: TargetApp, options: LauncherOptions) throws -> URL {
        let fm = FileManager.default
        let tz = options.timeZoneID
        guard TimeZoneCatalog.isValid(tz) else { throw BuildError.invalidTimeZone(tz) }
        if app.browserKind == .unsupported {
            throw BuildError.unsupportedBrowser("\(app.name):" + (AppInspector.unsupportedReason(app.bundleID) ?? "暂不支持"))
        }

        let tzName = TimeZoneCatalog.displayName(for: tz)
        let name = sanitizeFileName(options.customName ?? "\(app.name) \(tzName)")

        var dataDir: URL? = nil
        if app.browserKind == .chromium {
            let dir = options.dataDir ?? browserDataRoot.appendingPathComponent(
                "\(app.bundleID)-\(tz.replacingOccurrences(of: "/", with: "-"))", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            dataDir = dir
        }

        let script = launchScript(app: app, timeZoneID: tz, dataDir: dataDir,
                                  blockClaude: app.browserKind == .chromium && options.blockClaude)
        let rep = IconRenderer.badgedIcon(base: app.icon, badge: options.badge, color: options.badgeColor)
        let dest = try writeBundle(name: name, bundleID: launcherBundleID(app.bundleID, tz),
                                   script: script, icon: rep, replace: options.replace, meta: [
            "TZLKind": LauncherKind.timeZone.rawValue,
            "TZLTargetBundleID": app.bundleID,
            "TZLTargetName": app.name,
            "TZLTimeZone": tz,
            "TZLTimeZoneName": tzName,
            "TZLBadge": options.badge,
            "TZLBadgeColor": options.badgeColor.hexString,
            "TZLBrowserKind": app.browserKind.rawValue,
            "TZLBlockClaude": app.browserKind == .chromium && options.blockClaude,
            "TZLDataDir": dataDir?.path ?? "",
        ])

        // 独立实例开着时,直接点浏览器图标只会切到它;配一个「平时用的浏览器」快捷方式
        if app.browserKind == .chromium && options.addDefaultCompanion {
            do {
                try buildDefaultCompanion(for: app, replace: false)
            } catch BuildError.exists {
                // 已经有了,保留原样
            }
        }
        return dest
    }

    static func defaultCompanionName(for app: TargetApp) -> String {
        sanitizeFileName("\(app.name)（默认）")
    }

    /// 生成「平时用的浏览器」快捷方式:默认数据目录、系统时区,用 -n 强制另开实例
    @discardableResult
    static func buildDefaultCompanion(for app: TargetApp, replace: Bool) throws -> URL {
        guard app.browserKind == .chromium else {
            throw BuildError.unsupportedBrowser("\(app.name) 不是支持的浏览器")
        }
        let alert = "display alert \"找不到 \(appleScriptSafe(app.name))\" message \"它可能已被卸载。请在「时区启动器」里删除这个快捷方式。\" as warning"
        let script = [
            "#!/bin/bash",
            "# 由「时区启动器」生成:打开平时用的 \(app.name)(默认数据目录、系统时区)",
            "# 独立实例(例如北京时间那个)开着时,直接点浏览器图标只会切到它,所以这里用 -n 强制另开",
            "# 平时用的实例已经开着时,浏览器会把这次启动转交给它,打开一个新窗口",
            "/usr/bin/open -n -b \(sh(app.bundleID)) 2>/dev/null && exit 0",
            "/usr/bin/open -n -a \(sh(app.url.path)) 2>/dev/null && exit 0",
            "/usr/bin/osascript -e \(sh(alert)) >/dev/null 2>&1",
            "exit 1",
        ].joined(separator: "\n") + "\n"
        return try writeBundle(
            name: defaultCompanionName(for: app),
            bundleID: launcherBundleID(app.bundleID, "default"),
            script: script, icon: IconRenderer.plainIcon(base: app.icon), replace: replace,
            meta: [
                "TZLKind": LauncherKind.defaultBrowser.rawValue,
                "TZLTargetBundleID": app.bundleID,
                "TZLTargetName": app.name,
                "TZLTimeZone": "",
                "TZLTimeZoneName": "系统时区",
                "TZLBrowserKind": app.browserKind.rawValue,
                "TZLBlockClaude": false,
                "TZLDataDir": "",
            ])
    }

    /// 删除快捷方式(移到废纸篓,可恢复);浏览器数据只在明确要求时一起移走。
    /// 某个浏览器的独立实例快捷方式全删光后,配套的「平时用的」快捷方式也一起移走。
    static func remove(_ info: LauncherInfo, withData: Bool) throws {
        let fm = FileManager.default
        try fm.trashItem(at: info.url, resultingItemURL: nil)
        if withData, let dir = info.dataDir, fm.fileExists(atPath: dir) {
            try fm.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil)
        }
        guard info.browserKind == .chromium, info.kind == .timeZone else { return }
        let rest = LauncherInfo.scanAll().filter { $0.targetBundleID == info.targetBundleID }
        if !rest.contains(where: { $0.kind == .timeZone }) {
            for companion in rest where companion.kind == .defaultBrowser {
                try? fm.trashItem(at: companion.url, resultingItemURL: nil)
            }
        }
    }

    /// 在临时目录拼好快捷方式 App,再整体移到 launcherRoot,避免留下半成品
    private static func writeBundle(name: String, bundleID: String, script: String, icon: NSBitmapImageRep,
                                    replace: Bool, meta: [String: Any]) throws -> URL {
        let fm = FileManager.default
        let dest = launcherRoot.appendingPathComponent(name + ".app")
        try fm.createDirectory(at: launcherRoot, withIntermediateDirectories: true)
        ensureFolderIcon()
        if fm.fileExists(atPath: dest.path) {
            guard replace else { throw BuildError.exists(name) }
            try fm.trashItem(at: dest, resultingItemURL: nil)
        }

        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let bundle = work.appendingPathComponent(name + ".app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let exe = macOS.appendingPathComponent("launch")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try IconRenderer.writeICNS(icon, to: resources.appendingPathComponent("AppIcon.icns"))

        var info: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
            "TZLManaged": true,  // 时区启动器靠 TZL* 键识别和管理自己生成的快捷方式
        ]
        info.merge(meta) { _, new in new }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        try fm.moveItem(at: bundle, to: dest)
        LSRegisterURL(dest as CFURL, true)
        return dest
    }

    static func launchScript(app: TargetApp, timeZoneID tz: String, dataDir: URL?, blockClaude: Bool) -> String {
        var lines = [
            "#!/bin/bash",
            "# 由「时区启动器」生成:以 \(tz) 时区启动 \(app.name)(\(app.bundleID))",
        ]
        // 先按 bundle ID 找(App 升级、改名、挪位置都不影响),找不到再用生成时的路径
        var flags = "--env \(sh("TZ=" + tz))"
        var newInstance = ""
        if let dataDir {
            lines.append("# 浏览器使用独立的用户数据目录,和平时用的实例互不影响")
            if blockClaude { lines.append("# 屏蔽 \(blockedHosts.joined(separator: " / ")) 及其子域名") }
            newInstance = " -n"
            flags += " --args --user-data-dir=\(sh(dataDir.path))"
            if blockClaude { flags += " --host-rules=\(sh(hostRules))" }
        } else {
            lines.append("# App 已在运行时,open 只会把它切到前台,时区仍以它上次启动时为准")
        }
        let alert = "display alert \"找不到 \(appleScriptSafe(app.name))\" message \"它可能已被卸载。请在「时区启动器」里删除或重新生成这个快捷方式。\" as warning"
        lines.append("/usr/bin/open\(newInstance) -b \(sh(app.bundleID)) \(flags) 2>/dev/null && exit 0")
        lines.append("/usr/bin/open\(newInstance) -a \(sh(app.url.path)) \(flags) 2>/dev/null && exit 0")
        lines.append("/usr/bin/osascript -e \(sh(alert)) >/dev/null 2>&1")
        lines.append("exit 1")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 给快捷方式文件夹设置时钟图标(只设置一次)
    static func ensureFolderIcon() {
        let marker = launcherRoot.appendingPathComponent("Icon\r")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        NSWorkspace.shared.setIcon(IconRenderer.image(IconRenderer.clockIcon(text: "时")),
                                   forFile: launcherRoot.path, options: [])
    }

    // MARK: - 工具函数

    static func sh(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
    }

    private static func sanitizeFileName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func launcherBundleID(_ target: String, _ tz: String) -> String {
        let raw = "local.tzl.\(target).\(tz)"
        return String(raw.map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" })
    }
}

// MARK: - 子进程

enum Shell {
    struct Result {
        let status: Int32
        let out: Data
        let err: Data
        var errText: String { String(data: err, encoding: .utf8) ?? "" }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], input: Data? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { p.standardInput = inPipe }
        try p.run()
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: o, err: e)
    }
}

// MARK: - Dock

enum DockHelper {
    private static var folderURLString: String {
        launcherRoot.absoluteString.hasSuffix("/") ? launcherRoot.absoluteString : launcherRoot.absoluteString + "/"
    }

    private static func exportDock() throws -> [String: Any] {
        let r = try Shell.run("/usr/bin/defaults", ["export", "com.apple.dock", "-"])
        guard r.status == 0,
              let dict = try PropertyListSerialization.propertyList(from: r.out, format: nil) as? [String: Any]
        else { throw BuildError.io("读取 Dock 设置失败") }
        return dict
    }

    static func containsFolder() -> Bool {
        guard let dock = try? exportDock(),
              let others = dock["persistent-others"] as? [[String: Any]] else { return false }
        return others.contains { tile in
            let data = tile["tile-data"] as? [String: Any]
            let file = data?["file-data"] as? [String: Any]
            return (file?["_CFURLString"] as? String) == folderURLString
        }
    }

    /// 把快捷方式文件夹加到 Dock 右侧,以文件夹图标 + 网格方式显示
    static func addFolder() throws {
        guard !containsFolder() else { return }
        var dock = try exportDock()
        var others = dock["persistent-others"] as? [[String: Any]] ?? []
        others.insert([
            "tile-type": "directory-tile",
            "tile-data": [
                "file-label": launcherRoot.lastPathComponent,
                "file-type": 2,
                "displayas": 1,     // 文件夹图标
                "showas": 2,        // 网格
                "arrangement": 1,   // 按名称
                "file-data": ["_CFURLString": folderURLString, "_CFURLStringType": 15],
            ] as [String: Any],
        ], at: 0)
        dock["persistent-others"] = others
        let data = try PropertyListSerialization.data(fromPropertyList: dock, format: .xml, options: 0)
        let r = try Shell.run("/usr/bin/defaults", ["import", "com.apple.dock", "-"], input: data)
        guard r.status == 0 else { throw BuildError.io("写入 Dock 设置失败:" + r.errText) }
        try Shell.run("/usr/bin/killall", ["Dock"])
    }
}
