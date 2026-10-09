#!/usr/bin/env bash
# 推之前的本地预检：把 CI 会因为「补丁/依赖/类型」失败的事先在本机跑一遍。
#
#   ./scripts/preflight.sh                     # 上游 ref 取最新的 dsh-v* tag
#   ./scripts/preflight.sh dsh-v0.2.1-alpha.2   # 指定 ref
#   ./scripts/preflight.sh --full              # 额外跑 CI 同款 build:lib（含 tsdown，很慢）
#   ./scripts/preflight.sh --no-install        # 复用已有的 upstream/node_modules，跳过安装
#   ./scripts/preflight.sh --clean             # 跑完删掉 upstream/（含 node_modules，约 2.4G）
#
# 检查项（任何一项失败都返回非零）：
#   0. PKGBUILD 自洽：source 与 sha256sums 一一对应、逐个校验哈希（含下载 release 源码包），
#      并断言 patches/ 里的补丁与 source 列表完全一致——「加了补丁忘了写进 PKGBUILD」就是这么漏的
#   1. 拉上游 ref 到 ./upstream
#   2. 两条路径打同一套补丁：git apply（CI 用）与 GNU patch（makepkg 用），
#      并逐字节比对两条路径产出的树（README 里那条验收标准的机器版本）
#   3. pnpm install --frozen-lockfile
#   4. 类型检查：默认只跑 CI 会先跑到的 host 面（tsc -b tsconfig.host.json）；
#      --full 时连 client 面与 tsdown 一起跑
#
# 为什么 host 面单独跑就够当默认：CI 的 build:lib 是 host 先、client 后，而 client 面依赖
# host 面跑完 tsdown 才会生成的中间产物——只跑 client 的 tsc 会报一堆假错（remote-mock 的
# TypertRemoteNamespaceMap 就是这样）。所以默认只跑 host，要全链就 --full。
#
# 退出后 ./upstream 默认保留（下次跑只增量安装）；--clean 才会删掉它。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
REF=""
FULL=0
DO_INSTALL=1
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)       FULL=1 ;;
    --no-install) DO_INSTALL=0 ;;
    --clean)      CLEAN=1 ;;
    --help|-h)    sed -n '2,30p' "$0"; exit 0 ;;
    -*)           echo "未知参数：$1" >&2; exit 2 ;;
    *)            REF="$1" ;;
  esac
  shift
done

FAILED=()
step()  { printf '\n==> %s\n' "$*"; }
ok()    { printf '    ✓ %s\n' "$*"; }
bad()   { printf '    ✗ %s\n' "$*" >&2; FAILED+=("$*"); }
note()  { printf '    · %s\n' "$*"; }

# ---------------------------------------------------------------- 0. PKGBUILD 自洽
step "0/4 PKGBUILD 的 source 与 sha256sums 是否自洽"

mapfile -t -d '' PKG_SOURCES < <(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\0" "${source[@]}"' _ "$ROOT/PKGBUILD")
mapfile -t -d '' PKG_SUMS    < <(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\0" "${sha256sums[@]}"' _ "$ROOT/PKGBUILD")
PKG_TAG="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$_tag"' _ "$ROOT/PKGBUILD")"

if (( ${#PKG_SOURCES[@]} != ${#PKG_SUMS[@]} )); then
  bad "source 有 ${#PKG_SOURCES[@]} 项、sha256sums 有 ${#PKG_SUMS[@]} 项，数量必须一致"
else
  ok "source 与 sha256sums 各 ${#PKG_SOURCES[@]} 项"
fi

# patches/ 里的补丁必须与 source 列表完全一致（双向）。
pkg_patches=()
for entry in "${PKG_SOURCES[@]}"; do
  name="${entry##*::}"
  [[ "$name" == *.patch ]] && pkg_patches+=("$(basename "$name")")
done
disk_patches=()
shopt -s nullglob
for patchfile in "$ROOT"/patches/*.patch; do disk_patches+=("$(basename "$patchfile")"); done
if [[ "$(printf '%s\n' "${pkg_patches[@]}" | sort)" == "$(printf '%s\n' "${disk_patches[@]}" | sort)" ]]; then
  ok "patches/ 里 ${#disk_patches[@]} 个补丁与 PKGBUILD 的 source 列表一致"
else
  bad "patches/ 与 PKGBUILD 的 source 列表不一致："
  diff <(printf '%s\n' "${pkg_patches[@]}" | sort) <(printf '%s\n' "${disk_patches[@]}" | sort) | sed 's/^/      /' >&2 || true
fi

for i in "${!PKG_SOURCES[@]}"; do
  entry="${PKG_SOURCES[$i]}"; want="${PKG_SUMS[$i]:-}"
  name="${entry##*::}"
  if [[ "$entry" == *"://"* ]]; then
    # release 源码包：下载核对（上游重新生成 tag 压缩包时哈希会变，这正是这条检查的价值）。
    # 缓存名带上期望哈希的前 12 位：PKGBUILD 换了版本或哈希就会重新下载，不会拿旧文件顶包。
    url="$name"
    cache="${PREFLIGHT_CACHE:-${TMPDIR:-/tmp}}/$(basename "$url").${want:0:12}"
    if [[ ! -f "$cache" ]]; then
      note "下载 $(basename "$url")（约 33M）"
      curl -fsSL --max-time 600 -o "$cache" "$url" || { bad "下载失败：$url"; continue; }
    fi
    actual="$(sha256sum "$cache" | cut -d' ' -f1)"
    if [[ "$actual" == "$want" ]]; then
      ok "源码包 $(basename "$url") 哈希一致（tag $PKG_TAG）"
    else
      # 删掉不匹配的缓存，下次跑会重新下载再判一次；仍然不符就是 PKGBUILD 里的哈希该更新了。
      rm -f "$cache"
      bad "源码包哈希不符：$(basename "$url") 记录 ${want:0:12}… 实际 ${actual:0:12}…（已删缓存，重跑会重新下载）"
    fi
    continue
  fi
  local_path=""
  for candidate in "$ROOT/$name" "$ROOT/patches/$name" "$ROOT/assets/$name"; do
    [[ -f "$candidate" ]] && { local_path="$candidate"; break; }
  done
  if [[ -z "$local_path" ]]; then
    bad "找不到 $name（PKGBUILD 里列了但仓库里没有）"
    continue
  fi
  actual="$(sha256sum "$local_path" | cut -d' ' -f1)"
  [[ "$actual" == "$want" ]] || bad "哈希不符：$name 记录 ${want:0:12}… 实际 ${actual:0:12}…"
done
note "源码包缓存：${PREFLIGHT_CACHE:-${TMPDIR:-/tmp}}/（可用 PREFLIGHT_CACHE= 指定目录复用）"

# ---------------------------------------------------------------- 1. 拉上游
step "1/4 拉上游 ${REF:-最新 dsh-v* tag}"
if [[ -z "$REF" ]]; then
  REF="$(git ls-remote --tags --refs https://github.com/deepseek-ai/deepseek-harness.git 'dsh-v*' \
    | awk -F/ '{print $NF}' | sort -V | tail -1)"
fi
if [[ -z "$REF" ]]; then
  bad "无法确定上游 ref（网络不通？）"
  REF=""
else
  ok "ref = $REF"
  if REFRESH=1 "$ROOT/scripts/fetch-upstream.sh" "$REF" >/tmp/preflight-fetch.log 2>&1; then
    ok "已 checkout $(git -C "$UPSTREAM" rev-parse --short HEAD)"
  else
    bad "拉上游失败，见 /tmp/preflight-fetch.log"
    REF=""
  fi
fi

# ---------------------------------------------------------------- 2. 两条路径打补丁
if [[ -n "$REF" ]]; then
  step "2/4 两条路径打补丁并比对产物"

  # 每个改动/新增文件的 sha256 清单（untracked 与 modified 都算）；-z 免掉路径里的空白问题。
  # 排除 `.orig`/`.rej`：GNU patch 带偏移应用时会留下 `.orig` 备份，那是打补丁前的原文，
  # 与产物无关，纳入比对只会把「两条路径一致」判成假失败。
  manifest() {
    git -C "$UPSTREAM" status --short -z | while IFS= read -r -d '' entry; do
      f="${entry:3}"
      case "$f" in *.orig|*.rej) continue ;; esac
      [[ -f "$UPSTREAM/$f" ]] && sha256sum "$UPSTREAM/$f"
    done
  }
  reset_tree() { git -C "$UPSTREAM" reset --hard -q HEAD; git -C "$UPSTREAM" clean -fdq; }

  reset_tree
  if "$ROOT/scripts/apply-patches.sh" >/tmp/preflight-route-a.log 2>&1; then
    manifest > /tmp/preflight-manifest-a.txt
    ok "git apply 路线：$(wc -l < /tmp/preflight-manifest-a.txt) 个文件"
  else
    bad "git apply 路线失败，见 /tmp/preflight-route-a.log"
  fi

  reset_tree
  route_b_failed=0
  for patchfile in "$ROOT"/patches/*.patch; do
    if ! (cd "$UPSTREAM" && patch -Np1 -s -i "$patchfile" >/tmp/preflight-patch.log 2>&1); then
      bad "GNU patch 路线在 $(basename "$patchfile") 失败，见 /tmp/preflight-patch.log"
      route_b_failed=1
      break
    fi
  done
  if (( route_b_failed == 0 )); then
    # PKGBUILD 的 prepare() 也会把补丁装不下的二进制资产放进源码树。
    install -Dm644 "$ROOT/assets/tray-linux.png" "$UPSTREAM/apps/desktop/resources/tray-linux.png"
    manifest > /tmp/preflight-manifest-b.txt
    ok "GNU patch 路线：$(wc -l < /tmp/preflight-manifest-b.txt) 个文件"
  fi

  if [[ -f /tmp/preflight-manifest-a.txt && -f /tmp/preflight-manifest-b.txt ]]; then
    if diff -q /tmp/preflight-manifest-a.txt /tmp/preflight-manifest-b.txt >/dev/null; then
      ok "两条路径产出的树逐字节一致"
    else
      bad "两条路径产出的树不一致："
      diff /tmp/preflight-manifest-a.txt /tmp/preflight-manifest-b.txt | head -20 | sed 's/^/      /' >&2 || true
    fi
  fi
  reset_tree
fi

# ---------------------------------------------------------------- 3. 安装依赖
step "3/4 pnpm install --frozen-lockfile"
if [[ -z "$REF" ]]; then
  note "跳过（上游树不可用）"
elif (( DO_INSTALL == 0 )); then
  note "跳过（--no-install）"
else
  PNPM=(pnpm)
  if ! command -v pnpm >/dev/null 2>&1; then
    # 没有系统 pnpm 时退回桌面应用自带的那个（本机可能只剩应用在跑）。
    bundled="$(ls -t /tmp/.mount_*/resources/runtime/pnpm/bin/pnpm.mjs 2>/dev/null | head -1 || true)"
    if [[ -n "$bundled" ]] && command -v node >/dev/null 2>&1; then
      PNPM=(node "$bundled")
      note "用应用自带的 pnpm：$bundled"
    else
      bad "找不到 pnpm（也没找到应用自带的 ${bundled:-pnpm.mjs}）"
      PNPM=()
    fi
  fi
  if (( ${#PNPM[@]} > 0 )); then
    if (cd "$UPSTREAM" && "${PNPM[@]}" install --frozen-lockfile >/tmp/preflight-install.log 2>&1); then
      ok "依赖就绪（$(du -sh "$UPSTREAM/node_modules" | cut -f1)）"
    else
      bad "安装依赖失败，见 /tmp/preflight-install.log"
    fi
  fi
fi

# ---------------------------------------------------------------- 4. 类型检查
step "4/4 类型检查"
if [[ ! -d "$UPSTREAM/node_modules/typescript" ]]; then
  note "跳过（没有 node_modules；先去掉 --no-install 跑一次）"
elif (( FULL == 1 )); then
  note "--full：跑 CI 同款 build:lib（含 tsdown，慢，可能十几分钟）"
  if (cd "$UPSTREAM" && "${PNPM[@]}" run build:lib:host >/tmp/preflight-tsc.log 2>&1 \
      && "${PNPM[@]}" run build:lib:client >>/tmp/preflight-tsc.log 2>&1); then
    ok "build:lib:host + build:lib:client 通过，日志 /tmp/preflight-tsc.log"
  else
    bad "build:lib 失败，见 /tmp/preflight-tsc.log（尾部如下）"
    tail -15 /tmp/preflight-tsc.log | sed 's/^/      /' >&2 || true
  fi
else
  if (cd "$UPSTREAM" && node --max-old-space-size=4096 ./node_modules/typescript/bin/tsc -b tsconfig.host.json \
      >/tmp/preflight-tsc.log 2>&1); then
    ok "tsc -b tsconfig.host.json 通过"
  else
    bad "tsc -b tsconfig.host.json 失败，见 /tmp/preflight-tsc.log（尾部如下）"
    tail -15 /tmp/preflight-tsc.log | sed 's/^/      /' >&2 || true
  fi
  note "没跑 client 面与 tsdown；要全链加 --full"
fi

# ---------------------------------------------------------------- 收尾
if (( CLEAN == 1 )) && [[ -d "$UPSTREAM" ]]; then
  step "清理 upstream/（--clean）"
  du -sh "$UPSTREAM" 2>/dev/null | sed 's/^/    · 删除 /' || true
  rm -rf "$UPSTREAM"
  ok "已删除（下次跑会重新拉）"
fi

echo
if (( ${#FAILED[@]} == 0 )); then
  echo "==> 预检全部通过"
  exit 0
fi
echo "==> 预检失败 ${#FAILED[@]} 项：" >&2
for f in "${FAILED[@]}"; do echo "    ✗ $f" >&2; done
exit 1
