# Maintainer: ffyfox
# 从上游 monorepo 源码构建官方 DeepSeek Harness 桌面端（Linux）。
# 注意：这不是社区套壳版，是从 apps/desktop 构建的官方 Electron 桌面端。
#
# !! 此文件尚未端到端验证 !! 已验证的是：patches/ 全部 10 个补丁能干净应用，
#    package:linux:x64 全程走通并产出可运行的 AppImage（见 docs/findings.md 阶段 3）。
#    PKGBUILD 本身还没在干净的 makepkg 环境里跑过；deb / rpm 也还没做。
#
# 硬性前提：构建必须用 pnpm 11.x。仓库要求 packageManager: pnpm@11.7.0，
# 而 pnpm-workspace.yaml 用了 pnpm 10+ 的 overrides/allowBuilds/
# minimumReleaseAgeExclude —— pnpm 9 会报 ERR_PNPM_LOCKFILE_CONFIG_MISMATCH。

pkgname=deepseek-harness-desktop
pkgver=0.1.7rc2
pkgrel=1
_tag="v0.1.7-rc.2"
_srcdirname="deepseek-harness-0.1.7-rc.2"

pkgdesc="Official DeepSeek Harness desktop app for Linux (built from upstream monorepo)"
arch=('x86_64')
url="https://github.com/ffyfox/dsh-desktop-linux"
license=('custom')
depends=('gtk3' 'nss' 'libxss' 'libxtst' 'xdg-utils' 'at-spi2-core' 'libsecret')
makedepends=('nodejs' 'npm' 'pnpm' 'python' 'git' 'base-devel')
provides=('deepseek-harness-desktop')
conflicts=('deepseek-harness-desktop-git' 'dsh-desktop-git')
options=('!strip' '!emptydirs')
source=("$pkgname-$pkgver.tar.gz::https://github.com/deepseek-ai/deepseek-harness/archive/refs/tags/${_tag}.tar.gz")
sha256sums=('SKIP')

prepare() {
  cd "$srcdir/$_srcdirname"

  # 本项目维护的补丁（阶段 2 产出）。补丁目录可能为空。
  local patchdir="$startdir/patches"
  if [[ -d "$patchdir" ]]; then
    for p in "$patchdir"/*.patch; do
      [[ -e "$p" ]] || continue
      msg2 "applying $(basename "$p")"
      patch -Np1 -i "$p"
    done
  fi
}

build() {
  cd "$srcdir/$_srcdirname"
  export DSH_HOME="$srcdir/dsh-home"
  export ELECTRON_CACHE="$srcdir/electron-cache"

  local pnpm_major
  pnpm_major="$(pnpm --version | cut -d. -f1)"
  if (( pnpm_major < 11 )); then
    error "需要 pnpm 11.x，当前是 $(pnpm --version)。见 docs/findings.md"
    return 1
  fi

  # 强制更新策略通道是 Windows/macOS 专有的：策略服务只认 desktop-win / desktop-mac 客户端
  # 身份，Linux 没有对应身份，而且 Linux 产物没有更新通道，策略决定也驱动不了任何动作。
  # 因此 Linux 版不嵌入策略、也不轮询，上游要求必填的 *_ORIGIN 在这里用不到。
  cat > apps/desktop/.env.linux <<'EOF'
DSH_DESKTOP_APP_ID=com.deepseek.harness
EOF

  pnpm install --frozen-lockfile

  # Electron 二进制（~117MB）平时由 require('electron') 首次自动下载；
  # 打包前显式预热，保证离线/可复现。
  node apps/desktop/node_modules/electron/install.js

  pnpm --dir apps/desktop run package:linux:x64
}

package() {
  cd "$srcdir/$_srcdirname"

  # unsigned 构建的输出目录（见 electron-builder-config.mjs 的 directories.output）
  local unpacked="apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked"
  if [[ ! -d "$unpacked" ]]; then
    error "找不到 linux-unpacked，构建产物路径可能变了，见 docs/findings.md"
    return 1
  fi

  install -d "$pkgdir/opt/deepseek-harness-desktop"
  cp -a "$unpacked"/. "$pkgdir/opt/deepseek-harness-desktop/"

  install -d "$pkgdir/usr/bin"
  ln -s /opt/deepseek-harness-desktop/deepseek-harness \
        "$pkgdir/usr/bin/deepseek-harness-desktop"

  # dsh:// URL scheme
  install -d "$pkgdir/usr/share/applications"
  cat > "$pkgdir/usr/share/applications/deepseek-harness-desktop.desktop" <<'EOF'
[Desktop Entry]
Name=DeepSeek Harness
Comment=Official DeepSeek Harness desktop app
Exec=/opt/deepseek-harness-desktop/deepseek-harness %u
Terminal=false
Type=Application
Icon=deepseek-harness-desktop
Categories=Development;
MimeType=x-scheme-handler/dsh;
StartupWMClass=DeepSeek Harness
EOF

  local icon
  for icon in "$unpacked"/resources/*.png "$unpacked"/deepseek-harness.png; do
    [[ -e "$icon" ]] || continue
    install -Dm644 "$icon" "$pkgdir/usr/share/pixmaps/deepseek-harness-desktop.png"
    break
  done
}
