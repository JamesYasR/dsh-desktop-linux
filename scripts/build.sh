#!/usr/bin/env bash
# 在 ./upstream 里构建 Linux 桌面端。
#
#   ./scripts/build.sh --dir        # 只出未打包目录（快，先验证能不能起来）
#   ./scripts/build.sh              # 默认 AppImage
#   ./scripts/build.sh --deb        # deb
#   ./scripts/build.sh --rpm        # rpm
#   ./scripts/build.sh --all        # AppImage + deb + rpm
#
# 环境变量：
#   DSH_HOME  隔离的 dsh 数据目录，默认 /tmp/dsh-desktop-test
#
# !! 当前状态：链路能推进到 prepare:dsh，但会被 sharp 在 Electron 下的解码段错误挡住，
#    因此还产不出 linux-unpacked / AppImage。详见 docs/findings.md。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
export DSH_HOME="${DSH_HOME:-/tmp/dsh-desktop-test}"

[[ -d "$UPSTREAM/apps/desktop" ]] || { echo "找不到 $UPSTREAM/apps/desktop，先跑 fetch-upstream.sh" >&2; exit 1; }

# --- pnpm 11（仓库要求 packageManager: pnpm@11.7.0）---
PNPM="$(command -v pnpm || true)"
if [[ -z "$PNPM" || "$("$PNPM" --version)" != 11.* ]]; then
  FALLBACK="$HOME/.local/share/dsh-pnpm-11/node_modules/.bin/pnpm"
  if [[ -x "$FALLBACK" ]]; then
    PNPM="$FALLBACK"
    echo "==> 系统 pnpm 不是 11.x，改用隔离版：$("$PNPM" --version)"
  else
    echo "==> 需要 pnpm 11.x。安装隔离版：" >&2
    echo "    npm i --prefix ~/.local/share/dsh-pnpm-11 pnpm@11.7.0" >&2
    exit 1
  fi
fi

MODE="${1:---appimage}"
case "$MODE" in
  --dir)      SCRIPT="package:linux:x64:dir" ;;
  --appimage) SCRIPT="package:linux:x64" ;;
  --deb)      SCRIPT="package:linux:x64" ;;
  --rpm)      SCRIPT="package:linux:x64" ;;
  --all)      SCRIPT="package:linux:x64" ;;
  *) echo "未知参数：$MODE" >&2; exit 2 ;;
esac

# --- Linux 发布设置文件（上游按平台读 dotenv，Linux 用 .env.linux）---
ENV_FILE="$UPSTREAM/apps/desktop/.env.linux"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "==> $ENV_FILE 不存在，从 .env.linux.example 生成"
  cp "$UPSTREAM/apps/desktop/.env.linux.example" "$ENV_FILE"
  # policy origin 是必填项（即使是 unsigned 构建），先填占位值让构建能跑。
  sed -i -e 's|^DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN=$|DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN=https://example.invalid|' \
         -e 's|^DSH_DESKTOP_MANDATORY_UPDATE_PROD_ORIGIN=$|DSH_DESKTOP_MANDATORY_UPDATE_PROD_ORIGIN=https://example.invalid|' \
         "$ENV_FILE"
  echo "==> 注意：policy origin 目前是占位值 https://example.invalid。" >&2
  echo "    发布前必须替换成真实决策。见 docs/findings.md" >&2
fi

echo "==> DSH_HOME=$DSH_HOME"
echo "==> apps/desktop script: $SCRIPT"
mkdir -p "$DSH_HOME"

# 原生模块现状（2026-09-25 实测）：node-pty 与 sharp 的 linux-x64 二进制都随
# pnpm install 就位，BRIEF 里那两条已知阻塞点在当前版本不适用。
if ! find "$UPSTREAM/node_modules" -name 'pty.node' -print -quit 2>/dev/null | grep -q .; then
  echo "==> 警告：没找到 pty.node" >&2
fi

"$PNPM" --dir "$UPSTREAM/apps/desktop" run "$SCRIPT"
echo "==> 完成，产物见 $UPSTREAM/apps/desktop/.desktop-build/targets/linux-x64/artifacts"
