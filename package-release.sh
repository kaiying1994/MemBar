#!/bin/bash
# MemBar 发布打包 —— 编译 universal 二进制并产出可分发的 zip / dmg
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SRC_DIR"

APP_NAME="MemBar"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DIST="$SRC_DIR/dist"
APP="$DIST/stage/$APP_NAME.app"
ZIP="$DIST/${APP_NAME}-${VERSION}-macOS-universal.zip"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"

echo "==> MemBar $VERSION · universal (arm64 + x86_64)"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "--> 编译 arm64"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
    -o "$DIST/$APP_NAME.arm64" main.swift

echo "--> 编译 x86_64"
swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 \
    -o "$DIST/$APP_NAME.x86_64" main.swift

echo "--> lipo 合成 universal"
lipo -create "$DIST/$APP_NAME.arm64" "$DIST/$APP_NAME.x86_64" \
     -output "$APP/Contents/MacOS/$APP_NAME"
echo "    架构: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

cp Info.plist "$APP/Contents/Info.plist"
[ -f MemBar.icns ] && cp MemBar.icns "$APP/Contents/Resources/$APP_NAME.icns"

echo "--> ad-hoc 签名"
codesign --force --deep --sign - "$APP"

echo "--> 生成 zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "--> 生成 dmg"
DMGROOT="$DIST/dmgroot"
mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
cat > "$DMGROOT/安装说明.txt" <<'TXT'
MemBar 安装说明
================

1. 把左边的 MemBar.app 拖到右边的「应用程序」文件夹
2. 首次打开会被 macOS 拦下（未做 Apple 公证），二选一：
   · 右键点 MemBar.app → 打开 → 再点「打开」
   · 或打开「终端」执行：
       xattr -dr com.apple.quarantine /Applications/MemBar.app
3. 打开后菜单栏右上角会出现图标，没有 Dock 图标（菜单栏 App 的正常行为）
4. 开机自启：点菜单栏图标 → 面板里的开关

要求：macOS 13.0 或更高（Apple Silicon / Intel 均可）
源码 & 说明：https://github.com/kaiying1994/MemBar
TXT
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMGROOT" \
    -ov -format UDZO "$DMG" >/dev/null

rm -rf "$DIST/stage" "$DIST/$APP_NAME.arm64" "$DIST/$APP_NAME.x86_64" "$DIST/dmgroot"

echo ""
echo "==> 产物"
ls -lh "$ZIP" "$DMG" | awk '{printf "   %-8s %s\n", $5, $9}'
echo "==> 校验"
shasum -a 256 "$ZIP" "$DMG" | sed 's/^/   /'
