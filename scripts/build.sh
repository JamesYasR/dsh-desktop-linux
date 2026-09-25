#!/usr/bin/env bash
# 在 ./upstream 里构建 Linux 桌面端
#
#   ./scripts/build.sh --dir        # 只出未打包目录（快，先验证能不能起来）
#   ./scripts/build.sh              # 默认 AppImage
#   ./scripts/build.sh --deb        # deb
#   ./scripts/build.sh --rpm        # rpm
#   ./scripts/build.sh --all        # AppImage + deb + rpm
#
# 环境变量：
#   DSH_HOME  隔离的 dsh 数据目录，默认 /tmp/dsh-desktop-test
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
export DSH_HOME="${DSH_HOME:-/tmp/dsh-desktop-test}"

[[ -d "$UPSTREAM/apps/desktop" ]] || { echo "找不到 $UPSTREAM/apps/desktop，先跑 fetch-upstream.sh" >&2; exit 1; }

MODE="${1:---appimage}"
case "$MODE" in
  --dir)      SCRIPT="package:dir" ;;
  --appimage) SCRIPT="package:linux:x64" ;;
  --deb)      SCRIPT="package:linux:x64" ;;
  --rpm)      SCRIPT="package:linux:x64" ;;
  --all)      SCRIPT="package:linux:x64" ;;
  *) echo "未知参数：$MODE" >&2; exit 2 ;;
esac

echo "==> DSH_HOME=$DSH_HOME"
echo "==> apps/desktop script: $SCRIPT"
mkdir -p "$DSH_HOME"

# 原生模块兜底：node-pty 在 Linux 上没有 prebuild，安装脚本会静默 exit 0
# 却不产出 pty.node（上游 Discussion #605）。
if [[ "${SKIP_NATIVE_FIX:-0}" != "1" ]]; then
  PTY_DIR="$UPSTREAM/node_modules/.pnpm"
  if ! find "$UPSTREAM/node_modules" -name 'pty.node' -print -quit 2>/dev/null | grep -q .; then
    echo "==> 警告：没找到 pty.node，node-pty 可能没构建。见 BRIEF 已知阻塞点 1"
  fi
fi

pnpm --dir "$UPSTREAM/apps/desktop" run "$SCRIPT"
echo "==> 完成，产物见 $UPSTREAM/apps/desktop/dist 与 release/"
