#!/usr/bin/env bash
# 把一次 Linux 打包的产物目录当成 electron-updater 的 generic feed 提供出去。
#
#   ./scripts/serve-update-feed.sh            # 默认 127.0.0.1:8899
#   PORT=9000 ./scripts/serve-update-feed.sh
#
# 目录里必须有 electron-builder 生成的通道元数据（nightly-linux.yml）和它引用的 AppImage，
# 两者由 scripts/build.sh --appimage 产出。启动后把打印的 DSH_DESKTOP_LINUX_UPDATE_ORIGIN
# 用在同一台机器上跑的那个 AppImage 上，应用内的「检查更新」就会读这个 feed。
#
# 只在回环地址上提供明文 HTTP：应用侧只对回环主机接受 http，公网 feed 必须 HTTPS。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="${ARTIFACTS:-$ROOT/upstream/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts}"
PORT="${PORT:-8899}"

[[ -d "$ARTIFACTS" ]] || { echo "找不到产物目录 $ARTIFACTS，先跑 scripts/build.sh --appimage" >&2; exit 1; }

metadata="$(find "$ARTIFACTS" -maxdepth 1 -name '*-linux.yml' -print -quit)"
[[ -n "$metadata" ]] || { echo "$ARTIFACTS 里没有 *-linux.yml，这个构建没有嵌入更新 feed" >&2; exit 1; }
appimage="$(find "$ARTIFACTS" -maxdepth 1 -name '*.AppImage' -print -quit)"
[[ -n "$appimage" ]] || { echo "$ARTIFACTS 里没有 .AppImage，更新只能由 AppImage 自身安装" >&2; exit 1; }

echo "==> feed 目录：$ARTIFACTS"
echo "==> 通道元数据：$(basename "$metadata")"
echo "==> 载荷：$(basename "$appimage")"
echo
echo "DSH_DESKTOP_LINUX_UPDATE_ORIGIN=http://127.0.0.1:$PORT"
echo
echo "==> 服务地址 http://127.0.0.1:$PORT/ （Ctrl-C 停止）"
cd "$ARTIFACTS"
exec python3 -m http.server "$PORT" --bind 127.0.0.1
