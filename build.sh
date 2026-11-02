#!/bin/bash
# 构建「时区启动器.app」(只需要 Xcode Command Line Tools,不需要 Xcode 工程)
# 用法: ./build.sh            构建到 build/
#       ./build.sh --install  构建后复制到 ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="build/时区启动器.app"
rm -rf ./build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 同时编译 Apple 芯片和 Intel 版本,方便分享给别人
for arch in arm64 x86_64; do
    echo "编译 $arch ..."
    swiftc -O -parse-as-library -swift-version 5 \
        -target "$arch-apple-macos13.0" \
        Sources/*.swift -o "build/TimeZoneLauncher-$arch"
done
lipo -create build/TimeZoneLauncher-arm64 build/TimeZoneLauncher-x86_64 \
    -output "$APP/Contents/MacOS/TimeZoneLauncher"
rm -f build/TimeZoneLauncher-arm64 build/TimeZoneLauncher-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/TimeZoneLauncher" --write-tool-icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "已构建:$APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/时区启动器.app"
    cp -R "$APP" "$HOME/Applications/"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/时区启动器.app"
    echo "已安装:~/Applications/时区启动器.app"
fi
