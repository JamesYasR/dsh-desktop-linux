#!/usr/bin/env bash
# 以 dev 模式起官方桌面端窗口（不走打包流水线）。
#
#   ./scripts/dev-desktop.sh               # 构建后启动（默认会弹 DevTools）
#   ./scripts/dev-desktop.sh --no-build    # 跳过构建，直接启动
#   ./scripts/dev-desktop.sh --no-devtools # 不自动弹 DevTools
#
# 前提与坑：
#   1. 必须用 pnpm 11.7.0 —— 仓库的 pnpm-workspace.yaml 用了 pnpm 10+ 的
#      overrides/allowBuilds/minimumReleaseAgeExclude，pnpm 9 会报
#      ERR_PNPM_LOCKFILE_CONFIG_MISMATCH。
#   2. 干净树上必须先跑一次 `pnpm run build`：dev.ts 的 import 是静态提升的，
#      在它 main() 里那次构建之前就解析 lib/，否则 ERR_MODULE_NOT_FOUND。
#   3. 需要 patches/0001，否则 resolveDesktopBuildTarget() 抛
#      `unsupported target linux-x64`。
#   4. Electron 二进制（~117MB）由 require('electron') 首次自动下载，不必手动装；
#      离线构建请先预热 ELECTRON_CACHE。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
# 刻意不继承环境里的 DSH_HOME：DSH 会话自身把 DSH_HOME 指向用户真实的 ~/.dsh，直接继承会让
# 构建往正在使用的数据目录里写东西。要换路径请用 DSH_DESKTOP_LINUX_HOME。
export DSH_HOME="${DSH_DESKTOP_LINUX_HOME:-/tmp/dsh-desktop-test}"
if [[ "$DSH_HOME" == "$HOME/.dsh" ]]; then
  echo "错误：DSH_HOME 不能指向 $HOME/.dsh（正在使用的 dsh 数据目录）" >&2
  exit 1
fi

DO_BUILD=1
export DSH_DESKTOP_OPEN_DEVTOOLS="${DSH_DESKTOP_OPEN_DEVTOOLS:-1}"
for arg in "$@"; do
  case "$arg" in
    --no-build)    DO_BUILD=0 ;;
    --no-devtools) export DSH_DESKTOP_OPEN_DEVTOOLS=0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

# --- pnpm 11 ---
PNPM="$(command -v pnpm || true)"
if [[ -z "$PNPM" || "$("$PNPM" --version)" != 11.* ]]; then
  FALLBACK="$HOME/.local/share/dsh-pnpm-11/node_modules/.bin/pnpm"
  if [[ -x "$FALLBACK" ]]; then
    PNPM="$FALLBACK"
    echo "==> 系统 pnpm 不是 11.x，改用隔离版：$PNPM ($("$PNPM" --version))"
  else
    echo "==> 需要 pnpm 11.x。安装隔离版：" >&2
    echo "    npm i --prefix ~/.local/share/dsh-pnpm-11 pnpm@11.7.0" >&2
    exit 1
  fi
fi

[[ -d "$UPSTREAM/apps/desktop" ]] || { echo "找不到 $UPSTREAM，先跑 scripts/fetch-upstream.sh" >&2; exit 1; }
[[ -d "$UPSTREAM/node_modules" ]] || { echo "依赖没装，先 cd upstream && pnpm install --frozen-lockfile" >&2; exit 1; }

# --- 补丁检查 ---
if ! node --input-type=module -e "
import { resolveDesktopBuildTarget } from '$UPSTREAM/apps/desktop/scripts/desktop-build-paths.mjs'
resolveDesktopBuildTarget()
" >/dev/null 2>&1; then
  echo "==> target 解析失败，补丁没打全。跑 scripts/apply-patches.sh" >&2
  exit 1
fi

echo "==> DSH_HOME=$DSH_HOME"
mkdir -p "$DSH_HOME"

if (( DO_BUILD )); then
  echo "==> 全量构建（dev.ts 需要 lib/ 先存在）"
  ( cd "$UPSTREAM" && "$PNPM" run build )
  echo "==> 启动 dev 模式（构建 + 拉起 Electron）"
  ( cd "$UPSTREAM" && DSH_HOME="$DSH_HOME" "$PNPM" run dev:desktop )
else
  echo "==> 跳过构建，直接启动"
  ( cd "$UPSTREAM" && DSH_HOME="$DSH_HOME" "$PNPM" run start:desktop )
fi
