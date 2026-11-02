import AppKit

/// 生成的快捷方式统一放在这里,可以整个拖进 Dock 当文件夹用
let launcherRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/时区快捷方式", isDirectory: true)

/// 浏览器快捷方式使用的独立用户数据目录
let browserDataRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/时区启动器/浏览器数据", isDirectory: true)

// MARK: - 时区

struct TimeZonePreset: Identifiable, Hashable {
    let id: String      // IANA 时区名,也是传给 TZ 的值
    let name: String
    let badge: String
}

enum TimeZoneCatalog {
    static let presets: [TimeZonePreset] = [
        .init(id: "Asia/Shanghai", name: "北京", badge: "京"),
        .init(id: "Asia/Hong_Kong", name: "香港", badge: "港"),
        .init(id: "Asia/Taipei", name: "台北", badge: "台"),
        .init(id: "Asia/Tokyo", name: "东京", badge: "日"),
        .init(id: "Asia/Seoul", name: "首尔", badge: "韩"),
        .init(id: "Asia/Singapore", name: "新加坡", badge: "新"),
        .init(id: "Asia/Kolkata", name: "印度", badge: "印"),
        .init(id: "Asia/Dubai", name: "迪拜", badge: "迪"),
        .init(id: "Europe/London", name: "伦敦", badge: "英"),
        .init(id: "Europe/Paris", name: "巴黎", badge: "法"),
        .init(id: "Europe/Berlin", name: "柏林", badge: "德"),
        .init(id: "America/New_York", name: "纽约", badge: "纽"),
        .init(id: "America/Chicago", name: "芝加哥", badge: "芝"),
        .init(id: "America/Denver", name: "丹佛", badge: "丹"),
        .init(id: "America/Los_Angeles", name: "洛杉矶", badge: "洛"),
        .init(id: "Australia/Sydney", name: "悉尼", badge: "悉"),
        .init(id: "UTC", name: "UTC", badge: "UTC"),
    ]

    static let allIdentifiers: [String] =
        Array(Set(TimeZone.knownTimeZoneIdentifiers + presets.map(\.id))).sorted()

    static func preset(for id: String) -> TimeZonePreset? {
        presets.first { $0.id == id }
    }

    /// 以系统时区数据库为准:TZ 环境变量最终就是按这里的文件解析的。
    /// 苹果的 knownTimeZoneIdentifiers 不全(例如只有 Asia/Calcutta 没有 Asia/Kolkata),不能拿来判断。
    static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, !id.contains(".."), TimeZone(identifier: id) != nil else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: "/usr/share/zoneinfo/" + id, isDirectory: &isDir) && !isDir.boolValue
    }

    static func displayName(for id: String) -> String {
        if let p = preset(for: id) { return p.name }
        let city = id.split(separator: "/").last.map(String.init) ?? id
        return city.replacingOccurrences(of: "_", with: " ")
    }

    static func defaultBadge(for id: String) -> String {
        preset(for: id)?.badge ?? offsetLabel(for: id)
    }

    /// 例如 "+8"、"-5"、"+5:30"
    static func offsetLabel(for id: String, at date: Date = Date()) -> String {
        guard let tz = TimeZone(identifier: id) else { return "?" }
        let secs = tz.secondsFromGMT(for: date)
        let sign = secs >= 0 ? "+" : "-"
        let h = abs(secs) / 3600, m = (abs(secs) % 3600) / 60
        return m == 0 ? "\(sign)\(h)" : "\(sign)\(h):" + String(format: "%02d", m)
    }

    static func currentTime(in id: String, at date: Date = Date()) -> String {
        guard let tz = TimeZone(identifier: id) else { return "--:--" }
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: date) + "  UTC" + offsetLabel(for: id, at: date)
    }
}

// MARK: - 目标 App

enum BrowserKind: String {
    case none        // 普通 App
    case chromium    // 需要独立数据目录,可屏蔽 Claude 域名
    case unsupported // 网页由系统另起的进程渲染,或无法另开独立实例
}

enum AppInspector {
    static let chromiumPrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static let unsupportedBrowsers: [String: String] = [
        "com.apple.Safari": "Safari 的网页由系统另起的进程渲染,不会继承时区",
        "org.mozilla.firefox": "Firefox 暂未支持",
        "org.mozilla.firefoxdeveloperedition": "Firefox 暂未支持",
        "org.mozilla.nightly": "Firefox 暂未支持",
        "company.thebrowser.Browser": "Arc 无法另开独立数据的实例",
    ]

    static func browserKind(_ bundleID: String) -> BrowserKind {
        if unsupportedBrowsers[bundleID] != nil { return .unsupported }
        if chromiumPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return .chromium }
        return .none
    }

    static func unsupportedReason(_ bundleID: String) -> String? {
        unsupportedBrowsers[bundleID]
    }
}

struct TargetApp: Identifiable, Hashable {
    let url: URL
    let bundleID: String
    let name: String

    var id: String { bundleID }
    var browserKind: BrowserKind { AppInspector.browserKind(bundleID) }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    static func load(_ url: URL) -> TargetApp? {
        guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return TargetApp(url: url, bundleID: bid, name: name)
    }
}

// MARK: - 已生成的快捷方式

enum LauncherKind: String {
    case timeZone = "timezone"        // 以指定时区启动
    case defaultBrowser = "default"   // 浏览器「平时用的」实例:默认数据目录、系统时区
}

struct LauncherInfo: Identifiable, Hashable {
    let url: URL
    let kind: LauncherKind
    let targetBundleID: String
    let targetName: String
    let timeZoneID: String
    let timeZoneName: String
    let badge: String
    let browserKind: BrowserKind
    let blockClaude: Bool
    let dataDir: String?

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    var targetInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetBundleID) != nil
    }
    /// 「平时用的」快捷方式没有指定时区,跟随系统
    var effectiveTimeZoneID: String { kind == .defaultBrowser ? TimeZone.current.identifier : timeZoneID }

    static func load(_ url: URL) -> LauncherInfo? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              dict["TZLManaged"] as? Bool == true,
              let bid = dict["TZLTargetBundleID"] as? String
        else { return nil }
        // v1.0 生成的快捷方式没有 TZLKind,都按指定时区处理
        let kind = LauncherKind(rawValue: dict["TZLKind"] as? String ?? "") ?? .timeZone
        let tz = dict["TZLTimeZone"] as? String ?? ""
        guard kind == .defaultBrowser || !tz.isEmpty else { return nil }
        let dataDir = (dict["TZLDataDir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return LauncherInfo(
            url: url,
            kind: kind,
            targetBundleID: bid,
            targetName: dict["TZLTargetName"] as? String ?? bid,
            timeZoneID: tz,
            timeZoneName: dict["TZLTimeZoneName"] as? String ?? TimeZoneCatalog.displayName(for: tz),
            badge: dict["TZLBadge"] as? String ?? "",
            browserKind: BrowserKind(rawValue: dict["TZLBrowserKind"] as? String ?? "") ?? .none,
            blockClaude: dict["TZLBlockClaude"] as? Bool ?? false,
            dataDir: dataDir
        )
    }

    static func scanAll() -> [LauncherInfo] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: launcherRoot, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.pathExtension == "app" }
            .compactMap(load)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 颜色

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    static let defaultBadge = NSColor(srgbRed: 0.86, green: 0.12, blue: 0.12, alpha: 1)
}
