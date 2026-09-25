#!/usr/bin/env bash
# 组装一个可以直接 makepkg（也就是可以直接提交到 AUR）的平铺目录。
#
#   ./scripts/aur-dir.sh [输出目录]      # 默认 ./aur
#
# 为什么需要它：makepkg 只在 $startdir 里按 basename 找本地 source。把补丁放在
# patches/ 子目录里、source=('patches/0001-....patch') 会直接失败：
#
#   ==> ERROR: 0001-....patch was not found in the build directory and is not a URL.
#
# 所以 AUR 目录必须是 PKGBUILD + 补丁平铺在一起。仓库里保留 patches/ 是为了补丁系列
# 本身可读（编号 + README），发布时用这个脚本摊平。
#
# 输出目录里的内容是完整可提交的：PKGBUILD、.install、12 个补丁、.SRCINFO。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/aur}"

[[ -f "$ROOT/PKGBUILD" ]] || { echo "找不到 $ROOT/PKGBUILD" >&2; exit 1; }
[[ -d "$ROOT/patches" ]] || { echo "找不到 $ROOT/patches" >&2; exit 1; }

shopt -s nullglob
patches=("$ROOT"/patches/*.patch)
if (( ${#patches[@]} == 0 )); then
  echo "错误：$ROOT/patches 里没有 .patch 文件" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

cp "$ROOT/PKGBUILD" "$OUT/"
# install= 通常写成 "$pkgname.install"，所以先把 pkgname 取出来再展开。
pkgname_parsed="$(sed -n 's/^pkgname=\([^ ]*\)$/\1/p' "$ROOT/PKGBUILD" | head -1)"
install_name="$(sed -n 's/^install=["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}$/\1/p' "$ROOT/PKGBUILD" | head -1)"
install_name="${install_name//'$pkgname'/$pkgname_parsed}"
if [[ -n "$install_name" ]]; then
  [[ -f "$ROOT/$install_name" ]] || { echo "找不到 $ROOT/$install_name" >&2; exit 1; }
  cp "$ROOT/$install_name" "$OUT/"
fi

# 平铺：makepkg 按 basename 找，子目录不认。
cp "${patches[@]}" "$OUT/"

echo "==> 已摊平 ${#patches[@]} 个补丁到 $OUT"

if command -v makepkg >/dev/null 2>&1; then
  ( cd "$OUT" && makepkg --printsrcinfo > .SRCINFO )
  echo "==> 已生成 $OUT/.SRCINFO"
fi

cat <<EOF

下一步：
  cd "$OUT"
  makepkg -C -s --nocheck             # -C：构建前先清 \$srcdir
  makepkg --printsrcinfo > .SRCINFO   # 提交 AUR 前刷新

注意：本包只出未打包目录（package:linux:x64:dir），不打 AppImage/deb/rpm，
所以不需要 DSH_DESKTOP_LINUX_MAINTAINER / _HOMEPAGE。
EOF
