#!/bin/bash
# 启用 MemBar 开机自启
# 新版已改用苹果官方 SMAppService（等价于「系统设置 → 通用 → 登录项」），
# 不再依赖 launchctl bootstrap（该方法在本机上下文会报 EIO）
set -euo pipefail
APP="$HOME/Applications/MemBar.app"
BIN="$APP/Contents/MacOS/MemBar"

if [ ! -x "$BIN" ]; then
  echo "找不到 $BIN，请先运行 build.sh" >&2
  exit 1
fi

echo "==> 通过 SMAppService 注册登录项…"
"$BIN" --enable-autostart
echo ""
echo "可在「系统设置 → 通用 → 登录项」里看到 MemBar"
echo "关闭： bash uninstall-autostart.sh，或直接在 MemBar 面板里关掉「开机自启」开关"
