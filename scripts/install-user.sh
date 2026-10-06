#!/usr/bin/env bash
# 把构建出来的 AppImage 装进当前用户目录，并建立桌面快捷方式与应用菜单入口。
#
#   ./scripts/install-user.sh                 # 装到 ~/app（不需要 root）
#   APPDIR=~/Applications ./scripts/install-user.sh
#   TARGET_HOME=/home/someone ./scripts/install-user.sh
#
# 为什么装进用户目录而不是 /opt：应用内更新要替换正在运行的那个 AppImage 文件本身，
# 装到 root 拥有的目录里更新会失败。这里保持文件属主是当前用户。
#
# 安装结果：
#   ~/app/deepseek-harness.AppImage                           应用本体
#   ~/.local/share/icons/hicolor/{scalable,256x256,...}/apps/deepseek-harness.*
#   ~/.local/share/applications/deepseek-harness.desktop      桌面快捷方式 / 应用菜单
#
# 桌面条目与图标都取自 AppImage 自带的那一份（electron-builder 生成的），所以与 deb/rpm
# 安装出来的观感一致。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
ART="${ARTIFACTS:-$ROOT/upstream/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts}"

[[ "$TARGET_HOME" == /* ]] || { echo "TARGET_HOME 必须是绝对路径：$TARGET_HOME" >&2; exit 1; }

appimage="$(find "$ART" -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)"
[[ -n "$appimage" ]] || { echo "找不到 AppImage（$ART）；先跑 scripts/build.sh --appimage" >&2; exit 1; }

appdir="${APPDIR:-$TARGET_HOME/app}"
bin="$appdir/deepseek-harness.AppImage"
icons="$TARGET_HOME/.local/share/icons/hicolor/scalable/apps"
apps="$TARGET_HOME/.local/share/applications"

# 从 AppImage 里取 .desktop 与图标：这是 electron-builder 按上游 linux 配置生成的那一份。
extract="$(mktemp -d "$ROOT/.verify-install-XXXXXX")"
trap 'rm -rf "$extract"' EXIT
( cd "$extract" && "$appimage" --appimage-extract >/dev/null )
desktop_template="$(find "$extract/squashfs-root" -maxdepth 1 -name '*.desktop' -print -quit)"
icon_template="$(find "$extract/squashfs-root/usr/share/icons" -type f -print -quit)"
[[ -n "$desktop_template" && -n "$icon_template" ]] || { echo "AppImage 里没有 .desktop 或图标" >&2; exit 1; }

install -d "$appdir" "$icons" "$apps"
install -Dm755 "$appimage" "$bin"
install -Dm644 "$icon_template" "$icons/deepseek-harness.svg"

# 多尺寸 PNG：dock/任务栏按固定像素尺寸取图，只有可缩放 SVG 时个别实现会退回默认图标。
if command -v convert >/dev/null; then
  for size in 256 128 64 48; do
    install -d "$TARGET_HOME/.local/share/icons/hicolor/${size}x${size}/apps"
    convert -background none -density 384 "$icon_template" -resize "${size}x${size}" \
      "$TARGET_HOME/.local/share/icons/hicolor/${size}x${size}/apps/deepseek-harness.png" 2>/dev/null || true
  done
fi

# 保留模板里的 Name/Icon/StartupWMClass/MimeType/Categories，只把 Exec 换成装好的绝对路径。
# --class 强制窗口的 app_id / WM_CLASS：GNOME 就是拿它去找 <app_id>.desktop 并取图的。
# TryExec 必须**不带引号**：GIO 会把带引号的值当成一个不存在的可执行文件，于是把整个条目丢掉，
# 应用既不出现在应用列表里，运行中的窗口也匹配不到图标（只剩默认图标）。
sed -e "s|^Exec=.*|Exec=\"$bin\" --class=deepseek-harness %U|" \
    -e "s|^TryExec=.*|TryExec=$bin|" \
    "$desktop_template" > "$apps/deepseek-harness.desktop"
grep -q '^TryExec=' "$apps/deepseek-harness.desktop" || printf 'TryExec=%s\n' "$bin" >> "$apps/deepseek-harness.desktop"
chmod 0644 "$apps/deepseek-harness.desktop"

# 让桌面环境立刻看到新条目（缺工具时跳过，不是错误）。
command -v update-desktop-database >/dev/null && update-desktop-database "$apps" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t -f "$TARGET_HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo "==> 已安装：$bin"
echo "==> 桌面快捷方式：$apps/deepseek-harness.desktop"
echo "==> 图标：$icons/deepseek-harness.svg + hicolor/{48,64,128,256}/apps/deepseek-harness.png"
echo
sed 's/^/    /' "$apps/deepseek-harness.desktop"
