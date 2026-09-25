#!/usr/bin/env bash
# clone + checkout 上游 monorepo 到 ./upstream
#
#   ./scripts/fetch-upstream.sh              # master, --depth 1
#   ./scripts/fetch-upstream.sh v0.1.7-rc.2  # 指定 tag
#   REFRESH=1 ./scripts/fetch-upstream.sh    # 已存在则重新拉取
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/deepseek-ai/deepseek-harness.git}"
REF="${1:-master}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/upstream"

if [[ -d "$DEST/.git" ]]; then
  if [[ "${REFRESH:-0}" == "1" ]]; then
    echo "==> 已存在 $DEST，REFRESH=1，重新拉取 $REF"
    rm -rf "$DEST"
  else
    echo "==> $DEST 已存在，跳过（要重拉用 REFRESH=1）"
    git -C "$DEST" log --oneline -1
    exit 0
  fi
fi

echo "==> clone $REPO_URL @ $REF"
# 默认浅克隆；指定 tag 时也先浅克隆，失败再回退全量
if ! git clone --depth 1 --branch "$REF" "$REPO_URL" "$DEST" 2>/dev/null; then
  echo "==> 浅克隆 $REF 失败（可能是非分支 ref），回退全量克隆"
  rm -rf "$DEST"
  git clone "$REPO_URL" "$DEST"
  git -C "$DEST" checkout "$REF"
fi

echo "==> 完成"
git -C "$DEST" log --oneline -1
echo "==> 磁盘占用：$(du -sh "$DEST" | cut -f1)"
