import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主窗口

struct ContentView: View {
    @EnvironmentObject private var store: LauncherStore
    @State private var showingAdd = false
    @State private var pendingDelete: LauncherInfo?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.launchers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.launchers) { info in
                        LauncherRow(info: info) { pendingDelete = info }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            footer
        }
        .sheet(isPresented: $showingAdd) {
            AddLauncherView { store.reload() }
        }
        .sheet(item: $pendingDelete) { info in
            DeleteLauncherView(info: info) { withData in
                do {
                    try LauncherBuilder.remove(info, withData: withData)
                } catch {
                    errorMessage = error.localizedDescription
                }
                store.reload()
            }
        }
        .alert("出错了", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { store.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("时区启动器").font(.title2.weight(.semibold))
                Text("让选中的 App 以指定时区启动,系统时区保持不变")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingAdd = true
            } label: {
                Label("添加 App", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("还没有快捷方式").font(.headline)
            Text("点「添加 App」,从应用程序里选择要换时区的 App。")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(launcherRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("在 Finder 中显示") {
                    try? FileManager.default.createDirectory(at: launcherRoot, withIntermediateDirectories: true)
                    LauncherBuilder.ensureFolderIcon()
                    NSWorkspace.shared.activateFileViewerSelecting([launcherRoot])
                }
                Button(store.dockHasFolder ? "已在 Dock 中" : "添加到 Dock") {
                    do {
                        try FileManager.default.createDirectory(at: launcherRoot, withIntermediateDirectories: true)
                        LauncherBuilder.ensureFolderIcon()
                        try DockHelper.addFolder()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    store.reload()
                }
                .disabled(store.dockHasFolder)
            }
            Text("只有从这些快捷方式打开才会生效。App 自动更新后自己重启、开机自启、从通知或链接被唤起时,会回到系统时区;遇到时间不对,退出后再从快捷方式打开即可。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - 列表行

struct LauncherRow: View {
    let info: LauncherInfo
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.name).font(.headline)
                Text(info.kind == .defaultBrowser
                     ? "\(info.targetName) · 平时用的实例(默认数据、系统时区)"
                     : "\(info.targetName) · \(info.timeZoneName)(\(info.timeZoneID))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if info.browserKind == .chromium && info.kind == .timeZone {
                    Label("独立浏览器数据" + (info.blockClaude ? " · 已屏蔽 Claude" : ""), systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !info.targetInstalled {
                    Label("找不到目标 App,可能已被卸载", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            TimelineView(.everyMinute) { ctx in
                Text(TimeZoneCatalog.currentTime(in: info.effectiveTimeZoneID, at: ctx.date))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("打开") {
                NSWorkspace.shared.openApplication(at: info.url, configuration: NSWorkspace.OpenConfiguration())
            }
            .disabled(!info.targetInstalled)
            Menu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([info.url])
                }
                Divider()
                Button("删除…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 删除确认

struct DeleteLauncherView: View {
    let info: LauncherInfo
    let onConfirm: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var withData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: info.icon).resizable().frame(width: 44, height: 44)
                Text("删除「\(info.name)」?").font(.headline)
            }
            Text("快捷方式会被移到废纸篓,\(info.targetName) 本身不受影响。")
                .foregroundStyle(.secondary)
            if let dir = info.dataDir {
                Toggle("同时把这个浏览器的独立数据移到废纸篓", isOn: $withData)
                Text(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("里面有书签、登录状态和保存的密码。请先退出这个浏览器再删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) {
                    onConfirm(withData)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - 添加

struct AddLauncherView: View {
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let customTag = "__custom__"

    @State private var apps: [TargetApp] = []
    @State private var tzChoice = "Asia/Shanghai"
    @State private var customTZ = ""
    @State private var badge = "京"
    @State private var badgeEdited = false
    @State private var color = Color(nsColor: .defaultBadge)
    @State private var blockClaude = true
    @State private var addDefaultCompanion = true
    @State private var replaceExisting = false
    @State private var failures: [String] = []

    private var timeZoneID: String {
        tzChoice == Self.customTag ? customTZ.trimmingCharacters(in: .whitespaces) : tzChoice
    }
    private var tzValid: Bool { TimeZoneCatalog.isValid(timeZoneID) }
    private var buildable: [TargetApp] { apps.filter { $0.browserKind != .unsupported } }
    private var hasBrowser: Bool { apps.contains { $0.browserKind == .chromium } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                appsSection
                timeZoneSection
                badgeSection
                if hasBrowser { browserSection }
                Section {
                    Toggle("覆盖已存在的同名快捷方式", isOn: $replaceExisting)
                }
                if !failures.isEmpty {
                    Section("没有生成成功") {
                        ForEach(failures, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !buildable.isEmpty && tzValid {
                    Text("将生成 \(buildable.count) 个快捷方式")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("生成") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(buildable.isEmpty || !tzValid || badge.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onChange(of: timeZoneID) { newValue in
            if !badgeEdited, TimeZoneCatalog.isValid(newValue) {
                badge = TimeZoneCatalog.defaultBadge(for: newValue)
            }
        }
    }

    private var appsSection: some View {
        Section("App") {
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        if let why = AppInspector.unsupportedReason(app.bundleID) {
                            Text(why).font(.caption).foregroundStyle(.orange)
                        } else if app.browserKind == .chromium {
                            Text("浏览器:会使用独立的用户数据").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        apps.removeAll { $0.id == app.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                chooseApps()
            } label: {
                Label(apps.isEmpty ? "选择 App…" : "再选几个…", systemImage: "plus.app")
            }
        }
    }

    private var timeZoneSection: some View {
        Section("时区") {
            Picker("时区", selection: $tzChoice) {
                ForEach(TimeZoneCatalog.presets) { p in
                    Text("\(p.name)  ·  \(p.id)").tag(p.id)
                }
                Divider()
                Text("其他时区…").tag(Self.customTag)
            }
            if tzChoice == Self.customTag {
                TextField("时区名,例如 Asia/Bangkok", text: $customTZ)
                    .textFieldStyle(.roundedBorder)
                let query = customTZ.trimmingCharacters(in: .whitespaces)
                if !query.isEmpty && !tzValid {
                    let matches = TimeZoneCatalog.allIdentifiers
                        .filter { $0.localizedCaseInsensitiveContains(query) }
                        .prefix(6)
                    if matches.isEmpty {
                        Text("没有匹配的时区").font(.caption).foregroundStyle(.red)
                    } else {
                        ForEach(Array(matches), id: \.self) { id in
                            Button(id) { customTZ = id }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            if tzValid {
                LabeledContent("那里现在是") {
                    TimelineView(.everyMinute) { ctx in
                        Text(TimeZoneCatalog.currentTime(in: timeZoneID, at: ctx.date))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var badgeSection: some View {
        Section("图标角标") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("角标文字", text: Binding(
                        get: { badge },
                        set: { badge = String($0.prefix(4)); badgeEdited = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                    ColorPicker("角标颜色", selection: $color, supportsOpacity: false)
                    if badgeEdited {
                        Button("恢复默认文字") {
                            badgeEdited = false
                            badge = TimeZoneCatalog.defaultBadge(for: timeZoneID)
                        }
                        .buttonStyle(.link)
                    }
                }
                Spacer()
                if let first = apps.first {
                    Image(nsImage: IconRenderer.image(
                        IconRenderer.badgedIcon(base: first.icon, badge: badge, color: NSColor(color), size: 256)))
                        .resizable()
                        .frame(width: 88, height: 88)
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .frame(width: 88, height: 88)
                        .overlay(Text("预览").font(.caption).foregroundStyle(.tertiary))
                }
            }
        }
    }

    private var browserSection: some View {
        Section("浏览器") {
            Toggle("屏蔽 Claude / Anthropic 网站", isOn: $blockClaude)
            Text("浏览器会另开一个使用独立数据的实例,和平时用的浏览器互不影响,书签和登录需要重新设置。开启屏蔽后,这个实例打不开 claude.ai、claude.com、anthropic.com,避免在这个时区下访问 Claude。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("同时生成「平时用的浏览器」快捷方式", isOn: $addDefaultCompanion)
            Text("独立实例开着时,直接点浏览器图标只会切到它,打不开平时用的那个。这个快捷方式会强制另开平时用的浏览器(默认数据、系统时区)。已经有了就不会重复生成。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = "选择要换时区的 App"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let app = TargetApp.load(url),
                  !app.bundleID.hasPrefix("local.tzl."),
                  app.bundleID != Bundle.main.bundleIdentifier,
                  !apps.contains(where: { $0.id == app.id })
            else { continue }
            apps.append(app)
        }
    }

    private func generate() {
        failures = []
        var options = LauncherOptions(timeZoneID: timeZoneID, badge: badge)
        options.badgeColor = NSColor(color)
        options.blockClaude = blockClaude
        options.addDefaultCompanion = addDefaultCompanion
        options.replace = replaceExisting
        for app in buildable {
            do {
                try LauncherBuilder.build(for: app, options: options)
            } catch {
                failures.append("\(app.name):\(error.localizedDescription)")
            }
        }
        onDone()
        if failures.isEmpty { dismiss() }
    }
}
