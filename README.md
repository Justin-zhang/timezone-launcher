# 时区启动器

让选中的 macOS App 以指定时区启动，系统时区保持不变。

典型场景：系统时区被锁成美国（例如配合 claude-switcher 使用），但微信、飞书等日常 App 仍希望显示北京时间。

## 原理

启动时给 App 设置环境变量 `TZ`（`open -b <bundle-id> --env TZ=Asia/Shanghai`）。原生 App、Electron App 以及多数 Qt/Java 程序都会优先读取 `TZ`，只影响这一次启动的进程。

工具为每个 App 生成一个「快捷方式」小 App（带时区角标的图标 + 一段启动脚本），统一放在 `~/Applications/时区快捷方式/`，可以整个拖进 Dock 当文件夹用。

- 先按 bundle ID 找目标 App，找不到再用生成时记录的路径；都失败时弹窗提示
- Chromium 系浏览器（Chrome / Edge / Brave / Vivaldi / Opera）另开独立数据目录的实例，可选屏蔽 `claude.ai`、`claude.com`、`anthropic.com`（`--host-rules`）
- 浏览器同时生成一个「<浏览器>（默认）」快捷方式：独立实例开着时，直接点浏览器图标只会切到它（两者是同一个 bundle ID），这个快捷方式用 `open -n` 强制另开平时用的实例；平时的实例已开着时，浏览器会把启动转交给它并新开一个窗口。某个浏览器的时区快捷方式全部删掉后，它会一起被移走
- 生成时默认把原 App 从 Dock 左侧移除（可取消勾选，命令行用 `--keep-dock`），避免误点原图标以系统时区打开；App 运行时 Dock 里仍会出现它的图标。浏览器只在有「<浏览器>（默认）」快捷方式时才移除
- Safari、Firefox、Arc 不支持：Safari 的网页进程不继承环境变量，Firefox/Arc 暂未适配

## 局限

只有从快捷方式打开才生效。以下情况会回到系统时区：

- App 自动更新后自己重启
- App 自己的开机自启、系统「重新登录时重新打开窗口」（只记录 bundle ID 和路径，不记录环境变量）
- 从通知、链接、Dock 原图标唤起
- App 已在运行时点快捷方式只会切到前台，时区以它上次启动时为准
- 浏览器的两个实例同时开着时，其他 App 里点的链接交给哪个实例由系统决定；只开着独立实例时，链接会在它里面打开

## 构建

只需要 Xcode Command Line Tools，不需要 Xcode 工程。

```bash
./build.sh            # 构建到 build/（arm64 + x86_64，最低 macOS 13）
./build.sh --install  # 构建并安装到 ~/Applications/时区启动器.app
```

## 命令行模式

同一个可执行文件带参数运行时不启动界面，方便脚本化和自测：

```bash
T=~/Applications/时区启动器.app/Contents/MacOS/TimeZoneLauncher
$T --list
$T --create --app /Applications/WeChat.app --tz Asia/Shanghai [--badge 京] [--color "#DC1F1F"] [--name "微信 北京"] [--keep-dock] [--replace]
$T --create --app "/Applications/Google Chrome.app" --tz Asia/Shanghai --data-dir <目录> [--no-block-claude] [--no-default]
$T --add-default --app "/Applications/Google Chrome.app"   # 单独生成「平时用的浏览器」快捷方式
$T --remove "<快捷方式路径>" [--with-data]
$T --render-icon --app <App路径> --tz <时区> --out preview.png
$T --add-dock-folder
```

## 代码结构

| 文件 | 内容 |
|---|---|
| `Sources/Entry.swift` | 入口、SwiftUI App、命令行模式 |
| `Sources/Models.swift` | 时区目录、目标 App、已生成快捷方式的读取 |
| `Sources/LauncherBuilder.swift` | 生成/删除快捷方式、启动脚本、Dock 文件夹、移除原 App 的 Dock 图标 |
| `Sources/IconRenderer.swift` | 角标图标、时钟图标、`.icns` 输出 |
| `Sources/Views.swift` | 主窗口、添加、删除界面 |

快捷方式的元数据写在它自己的 `Info.plist` 里（`TZLManaged`、`TZLTargetBundleID`、`TZLTimeZone` 等），工具靠这些键识别和管理。

## 验证方法

做一个只会把 `TimeZone.current` 写进文件的小 App，给它生成快捷方式后启动，读文件确认时区。注意编译测试 App 时要指定 `-target arm64-apple-macos13.0`，否则 swiftc 默认的最低系统版本可能高于本机，系统会拒绝打开（`-10825`）。

## 待办

- 「登录时打开」开关（用 LaunchAgent 打开快捷方式），并检测原 App 自身的开机自启
- 浏览器快捷方式：从现有 Chrome 用户资料导入
- Firefox 支持（`-no-remote -profile`）
