#!/usr/bin/env bash
# 跟进上游新版本：把 ./upstream 切到新的 ref，重新打补丁，按需重建与重装。
#
#   ./scripts/upgrade.sh --check            # 只验证补丁能不能打上（成功则保持已应用，失败则回滚）
#   ./scripts/upgrade.sh --check dsh-v0.2.2 # 指定 ref
#   ./scripts/upgrade.sh                    # 全流程：切 ref + 打补丁 + 装依赖 + 构建 AppImage + 重装
#   ./scripts/upgrade.sh --build dsh-v0.2.2 # 同上，指定 ref
#
# 为什么不是 git merge：patches/ 里每个 diff 都相对 PKGBUILD 的 _tag 那个 commit 生成，上游一换
# 基线就得重新验证。而且 0016–0018 是**叠加**在 0001–0015 之上的，所以只能按文件名顺序逐个真实
# 应用（不能各自对着干净基线 --check，那必然误报失败）。这个脚本把验证、构建、重装串起来。
#
# 环境变量：
#   DSH_DESKTOP_LINUX_HOME 传给 build.sh 的隔离数据目录
#   UPGRADE_SKIP_INSTALL=1 只构建，不重装到 ~/.local
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
REPO_URL="${REPO_URL:-https://github.com/deepseek-ai/deepseek-harness.git}"

MODE="full"
case "${1:-}" in
  --check) MODE="check"; shift ;;
  --build) MODE="full"; shift ;;
  "") ;;
  *) echo "未知参数：$1（可用：--check / --build）" >&2; exit 2 ;;
esac
REF="${1:-}"

[[ -d "$UPSTREAM/.git" ]] || { echo "找不到 $UPSTREAM，先跑 scripts/fetch-upstream.sh" >&2; exit 1; }

# --- 解析目标 ref：默认取上游最新的 dsh-v* tag ---
if [[ -z "$REF" ]]; then
  echo "==> 查询上游最新 tag"
  # || true：网络失败时让它落到下面那条明确报错，而不是被 set -e 用管道退出码带走。
  REF="$(git ls-remote --tags --refs "$REPO_URL" 'dsh-v*' | awk -F/ '{print $NF}' | sort -V | tail -1 || true)"
  [[ -n "$REF" ]] || { echo "查不到上游 dsh-v* tag（网络或仓库地址问题？）" >&2; exit 1; }
fi

# 补丁新增的文件（`--- /dev/null` 那一侧）。它们不在 HEAD 里，reset 不会删，必须显式清掉，
# 否则下一次 apply 会撞上「文件已存在」。
patch_added_files() {
  local patch
  for patch in "$ROOT"/patches/*.patch; do
    awk '/^new file mode/{new=1} new && /^\+\+\+ b\//{print substr($0,7); new=0}' "$patch"
  done
}

# 只看受跟踪文件的改动：撤销补丁会连带撤掉 .gitignore 里对 apps/desktop/.env.linux 的忽略，
# 于是本地设置文件会以「未跟踪」的形式冒出来，那不是脏工作树。
tracked_dirty() { [[ -n "$(git -C "$UPSTREAM" status --porcelain | grep -vE '^\?\?' | head -1)" ]]; }

# 把 upstream 拉回当前 HEAD 的干净状态。用硬重置而不是反向打补丁：`git apply --3way` 失败会留下
# 冲突标记与 unmerged 索引项，那种状态下后续的 `git apply --reverse` 全部会失败，反向撤销救不回来。
hard_reset_upstream() {
  echo "==> 重置 upstream 到当前基线（丢弃补丁改动，保留未跟踪的本地设置与构建缓存）"
  git -C "$UPSTREAM" reset --hard HEAD >/dev/null
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] && rm -f "$UPSTREAM/$file"
  done < <(patch_added_files)
}

# --- 先撤销当前已应用的补丁，否则切 ref 会带着改动冲突 ---
if tracked_dirty; then
  echo "==> 撤销当前已应用的补丁"
  "$ROOT/scripts/apply-patches.sh" --revert >/dev/null 2>&1 || true
fi
if tracked_dirty; then
  hard_reset_upstream
fi
if tracked_dirty; then
  echo "错误：工作树在重置后仍不干净，先手工处理：" >&2
  git -C "$UPSTREAM" status --short | head -20 >&2
  exit 1
fi

# --- 切到目标 ref（就地 fetch + checkout，保留 node_modules 与构建缓存）---
echo "==> 拉取 $REF"
git -C "$UPSTREAM" fetch --depth 1 "$REPO_URL" "+refs/tags/$REF:refs/tags/$REF" 2>/dev/null \
  || git -C "$UPSTREAM" fetch --depth 1 "$REPO_URL" "$REF"
git -C "$UPSTREAM" checkout --detach FETCH_HEAD
BASE="$(git -C "$UPSTREAM" rev-parse --short HEAD)"
echo "==> 基线 $REF ($BASE)"

# 上轮留下的补丁新增文件不在 HEAD 里，留着会让 apply 撞「文件已存在」。
while IFS= read -r file; do
  [[ -n "$file" && -e "$UPSTREAM/$file" ]] && rm -f "$UPSTREAM/$file"
done < <(patch_added_files)

print_rework_help() {
  local failed="$1"
  echo
  echo "==> 补丁 $failed 打不上，需要重做后再构建。"
  cat <<EOF

重做步骤：
  1. 看这个补丁改了哪些文件：  grep '^diff --git' "$ROOT/patches/$failed"
  2. 看上游在这个基线里把这几处改成了什么：
       git -C upstream log --oneline -5 -- <该补丁涉及的文件>
  3. 先让能打上的补丁按序打上（./scripts/upgrade.sh --check 会把树留在能打到的位置），
     再在树上手工改同一处
  4. 重新生成该补丁并把改动收敛进这个文件：
       git -C upstream diff -- <该补丁涉及的文件> > "$ROOT/patches/$failed"
     注意 0001–0015 相对干净基线、0016–0018 叠加在其上，顺序不能改。
  5. 同步 PKGBUILD 里该补丁的 sha256；换了基线还要改 _tag / _commit
  6. 重跑 ./scripts/upgrade.sh --check 直到全绿
EOF
}

# --- 按序逐个真实应用：叠加补丁必须看到前面的结果 ---
applied=0
failed=""
shopt -s nullglob
for patch in "$ROOT"/patches/*.patch; do
  name="$(basename "$patch")"
  if git -C "$UPSTREAM" apply "$patch" 2>/dev/null; then
    printf '  [ OK ] %s\n' "$name"
  elif git -C "$UPSTREAM" apply --3way "$patch" 2>/dev/null; then
    printf '  [3WAY] %s（上下文有移动，已三方合并，请复核结果）\n' "$name"
  else
    printf '  [FAIL] %s\n' "$name"
    # 诊断输出而已：这条管道本身是非零退出，不加 || true 会被 set -e 直接带走，回滚就永远不会执行。
    git -C "$UPSTREAM" apply --check -v "$patch" 2>&1 | grep -E '^error' | head -3 | sed 's/^/         /' || true
    failed="$name"
    break
  fi
  applied=$((applied + 1))
done

if [[ -n "$failed" ]]; then
  echo "==> 回滚（已成功应用 $applied 个补丁）"
  hard_reset_upstream
  if tracked_dirty; then
    echo "警告：回滚后工作树仍不干净：" >&2
    git -C "$UPSTREAM" status --short | head -10 >&2
  fi
  print_rework_help "$failed"
  exit 1
fi

# 补丁装不下的二进制资产（与 scripts/apply-patches.sh 的 ASSETS 同一批）。
install -Dm644 "$ROOT/assets/tray-linux.png" "$UPSTREAM/apps/desktop/resources/tray-linux.png"

if [[ "$MODE" == "check" ]]; then
  echo
  echo "==> 全部补丁可打，且已应用在这棵树上；直接跑 scripts/build.sh --appimage 即可构建。"
  exit 0
fi

echo "==> 安装依赖（lockfile 可能随上游变）"
command -v pnpm >/dev/null || { echo "找不到 pnpm" >&2; exit 1; }
( cd "$UPSTREAM" && pnpm install --frozen-lockfile )

echo "==> 构建 AppImage"
"$ROOT/scripts/build.sh" --appimage

if [[ "${UPGRADE_SKIP_INSTALL:-0}" == "1" ]]; then
  echo "==> UPGRADE_SKIP_INSTALL=1，跳过安装"
  exit 0
fi

echo "==> 重装到 ~/.local 并刷新桌面快捷方式"
"$ROOT/scripts/install-user.sh"

echo "==> 完成：$REF"
