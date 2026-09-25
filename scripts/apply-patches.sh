#!/usr/bin/env bash
# 把 patches/*.patch 按文件名顺序打进 ./upstream
#
#   ./scripts/apply-patches.sh          # 打补丁
#   ./scripts/apply-patches.sh --check  # 只试打，不落盘
#   ./scripts/apply-patches.sh --revert # 反打（撤销）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
PATCH_DIR="$ROOT/patches"

MODE="apply"
case "${1:-}" in
  --check)  MODE="check" ;;
  --revert) MODE="revert" ;;
  "")       ;;
  *) echo "未知参数：$1" >&2; exit 2 ;;
esac

[[ -d "$UPSTREAM/.git" ]] || { echo "找不到 $UPSTREAM，先跑 scripts/fetch-upstream.sh" >&2; exit 1; }

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if (( ${#patches[@]} == 0 )); then
  echo "==> patches/ 里没有 .patch 文件，无事可做"
  exit 0
fi

# --revert 要逆序撤销
if [[ "$MODE" == "revert" ]]; then
  for (( i=${#patches[@]}-1; i>=0; i-- )); do
    p="${patches[$i]}"
    echo "==> revert $(basename "$p")"
    git -C "$UPSTREAM" apply --reverse "$p"
  done
  echo "==> 全部撤销完成"
  exit 0
fi

for p in "${patches[@]}"; do
  name="$(basename "$p")"
  if [[ "$MODE" == "check" ]]; then
    echo "==> check $name"
    git -C "$UPSTREAM" apply --check "$p"
  else
    echo "==> apply $name"
    git -C "$UPSTREAM" apply "$p"
  fi
done

echo "==> 完成（$MODE）"
