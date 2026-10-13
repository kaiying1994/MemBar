#!/bin/bash
# 停用 MemBar 开机自启（走 SMAppService）
set -euo pipefail
APP="$HOME/Applications/MemBar.app"
BIN="$APP/Contents/MacOS/MemBar"

if [ ! -x "$BIN" ]; then
  echo "找不到 $BIN，请先运行 build.sh" >&2
  exit 1
fi

# 顺手清掉旧版 launchd 方案可能残留的 plist
rm -f "$HOME/Library/LaunchAgents/link.nlyenhits.membar.plist"

echo "==> 通过 SMAppService 注销登录项…"
"$BIN" --disable-autostart
echo "程序本身仍在运行，退出请用菜单栏面板里的「退出」"
