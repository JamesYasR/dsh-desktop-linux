# Maintainer: ffyfox
# 从上游 monorepo 源码构建官方 DeepSeek Harness 桌面端（Linux）。
# 注意：这不是社区套壳版，是从 apps/desktop 构建的官方 Electron 桌面端。
#
# 构建前请阅读 docs/findings.md 里的已知阻塞点（node-pty / sharp / package-target）。

pkgname=deepseek-harness-desktop
pkgver=0.1.7rc2
pkgrel=1
pkgdesc="Official DeepSeek Harness desktop app for Linux (built from upstream monorepo)"
arch=('x86_64')
url="https://github.com/ffyfox/dsh-desktop-linux"
license=('custom')
depends=('gtk3' 'nss' 'libxss' 'libxtst' 'xdg-utils' 'at-spi2-core' 'libsecret')
makedepends=('nodejs' 'npm' 'pnpm' 'python' 'git' 'base-devel')
provides=('deepseek-harness-desktop')
conflicts=('deepseek-harness-desktop-git' 'dsh-desktop-git')
options=('!strip' '!emptydirs')
source=("$pkgname-$pkgver.tar.gz::https://github.com/deepseek-ai/deepseek-harness/archive/refs/tags/v${pkgver/rc/.rc}.tar.gz")
noextract=()
sha256sums=('SKIP')

prepare() {
  cd "$srcdir/deepseek-harness-${pkgver/rc/.rc}"

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
  cd "$srcdir/deepseek-harness-${pkgver/rc/.rc}"
  export DSH_HOME="$srcdir/dsh-home"
  export ELECTRON_CACHE="$srcdir/electron-cache"

  pnpm install --frozen-lockfile
  pnpm --dir apps/desktop run package:linux:x64
}

package() {
  cd "$srcdir/deepseek-harness-${pkgver/rc/.rc}"

  local unpacked="apps/desktop/dist/linux-unpacked"
  [[ -d "$unpacked" ]] || unpacked="apps/desktop/release/linux-unpacked"
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
