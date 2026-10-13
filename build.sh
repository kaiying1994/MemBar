#!/bin/bash
# MemBar 构建脚本 —— 原生编译，无第三方依赖
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/MemBar.app"
BIN_NAME="MemBar"

echo "==> 编译 main.swift"
swiftc -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -o "$SRC_DIR/$BIN_NAME" \
    "$SRC_DIR/main.swift"

echo "==> 组装 app bundle: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$SRC_DIR/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
[ -f "$SRC_DIR/MemBar.icns" ] && cp "$SRC_DIR/MemBar.icns" "$APP_DIR/Contents/Resources/MemBar.icns"

echo "==> 临时签名 (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP_DIR" 2>/dev/null || echo "   (签名跳过，不影响运行)"

echo "==> 完成：$APP_DIR"
