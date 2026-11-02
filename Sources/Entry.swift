import AppKit
import SwiftUI

@main
struct Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, CLI.commands.contains(first) {
            exit(CLI.run(args))
        }
        TimeZoneLauncherApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct TimeZoneLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = LauncherStore()

    var body: some Scene {
        WindowGroup("时区启动器") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 680, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
    }
}

final class LauncherStore: ObservableObject {
    @Published var launchers: [LauncherInfo] = []
    @Published var dockHasFolder = false

    func reload() {
        launchers = LauncherInfo.scanAll()
        dockHasFolder = DockHelper.containsFolder()
    }
}

// MARK: - 命令行(脚本化和自测用)

enum CLI {
    static let commands: Set<String> = ["--list", "--create", "--add-default", "--remove", "--render-icon", "--write-tool-icns", "--add-dock-folder", "--help"]

    static let usage = """
    用法:
      时区启动器 --list
      时区启动器 --create --app <App路径> --tz <时区> [--badge 文字] [--color #RRGGBB]
                         [--name 名称] [--no-block-claude] [--no-default] [--keep-dock] [--data-dir 目录] [--replace]
      时区启动器 --add-default --app <浏览器路径> [--replace]
      时区启动器 --remove <快捷方式路径> [--with-data]
      时区启动器 --render-icon --app <App路径> --tz <时区> [--badge 文字] [--color #RRGGBB] --out <png>
      时区启动器 --write-tool-icns <icns路径>
      时区启动器 --add-dock-folder
    """

    static func run(_ args: [String]) -> Int32 {
        var opts: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        var i = 1
        while i < args.count {
            let a = args[i]
            if ["--app", "--tz", "--badge", "--color", "--name", "--data-dir", "--out"].contains(a), i + 1 < args.count {
                opts[a] = args[i + 1]; i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a); i += 1
            } else {
                positional.append(a); i += 1
            }
        }

        do {
            switch args[0] {
            case "--list":
                for l in LauncherInfo.scanAll() {
                    var line = "\(l.name)\t\(l.targetName) (\(l.targetBundleID))\t"
                    line += l.kind == .defaultBrowser ? "平时用的实例(系统时区)" : l.timeZoneID
                    if l.browserKind == .chromium && l.kind == .timeZone {
                        line += "\t浏览器" + (l.blockClaude ? "·屏蔽Claude" : "") + "\t\(l.dataDir ?? "")"
                    }
                    if !l.targetInstalled { line += "\t[目标 App 未安装]" }
                    print(line)
                }
            case "--create":
                let (app, tz) = try appAndTZ(opts)
                var o = LauncherOptions(timeZoneID: tz, badge: opts["--badge"] ?? TimeZoneCatalog.defaultBadge(for: tz))
                if let c = opts["--color"] { o.badgeColor = NSColor(hex: c) ?? .defaultBadge }
                o.customName = opts["--name"]
                o.blockClaude = !flags.contains("--no-block-claude")
                o.dataDir = opts["--data-dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                o.replace = flags.contains("--replace")
                o.addDefaultCompanion = !flags.contains("--no-default")
                let url = try LauncherBuilder.build(for: app, options: o)
                print("已生成:\(url.path)")
                if !flags.contains("--keep-dock"), LauncherBuilder.canRemoveOriginalFromDock(app),
                   try DockHelper.removeApps([app]) > 0 {
                    print("已从 Dock 移除原图标:\(app.name)")
                }
            case "--add-default":
                guard let path = opts["--app"], let app = TargetApp.load(URL(fileURLWithPath: path)) else {
                    throw BuildError.io("缺少或无效的 --app")
                }
                let url = try LauncherBuilder.buildDefaultCompanion(for: app, replace: flags.contains("--replace"))
                print("已生成:\(url.path)")
            case "--remove":
                guard let p = positional.first, let info = LauncherInfo.load(URL(fileURLWithPath: p)) else {
                    throw BuildError.io("不是时区启动器生成的快捷方式")
                }
                try LauncherBuilder.remove(info, withData: flags.contains("--with-data"))
                print("已移到废纸篓:\(info.url.path)")
            case "--render-icon":
                let (app, tz) = try appAndTZ(opts)
                guard let out = opts["--out"] else { throw BuildError.io("缺少 --out") }
                let rep = IconRenderer.badgedIcon(base: app.icon, badge: opts["--badge"] ?? TimeZoneCatalog.defaultBadge(for: tz),
                                                  color: opts["--color"].flatMap { NSColor(hex: $0) } ?? .defaultBadge)
                try IconRenderer.pngData(rep, pixels: 256)?.write(to: URL(fileURLWithPath: out))
                print("已输出:\(out)")
            case "--write-tool-icns":
                guard let p = positional.first else { throw BuildError.io("缺少输出路径") }
                try IconRenderer.writeICNS(IconRenderer.clockIcon(text: "时"), to: URL(fileURLWithPath: p))
            case "--add-dock-folder":
                try FileManager.default.createDirectory(at: launcherRoot, withIntermediateDirectories: true)
                LauncherBuilder.ensureFolderIcon()
                try DockHelper.addFolder()
                print("已加入 Dock:\(launcherRoot.path)")
            default:
                print(usage)
            }
            return 0
        } catch {
            FileHandle.standardError.write(("错误:" + error.localizedDescription + "\n").data(using: .utf8)!)
            return 1
        }
    }

    private static func appAndTZ(_ opts: [String: String]) throws -> (TargetApp, String) {
        guard let path = opts["--app"], let app = TargetApp.load(URL(fileURLWithPath: path)) else {
            throw BuildError.io("缺少或无效的 --app")
        }
        guard let tz = opts["--tz"], TimeZoneCatalog.isValid(tz) else {
            throw BuildError.invalidTimeZone(opts["--tz"] ?? "(未指定)")
        }
        return (app, tz)
    }
}
