# Maintainer: ffyfox <299493445+ffyfox@users.noreply.github.com>
#
# 官方 DeepSeek Harness 桌面端（Linux），从上游 monorepo 的 release 源码包构建。
# 这不是社区套壳版：跑的就是上游 apps/desktop 的 Electron 打包流水线。
#
# 本目录里的 *.patch 是补丁系列（见 patches/README.md）。它们必须平铺在 PKGBUILD 旁边：
# makepkg 只在 PKGBUILD 所在目录里按 basename 找本地 source，放进 patches/ 子目录会直接报
# "<file> was not found in the build directory and is not a URL"（实测）。用
# scripts/pkgbuild-dir.sh 从仓库根目录生成这个平铺目录。
#
# 注意：namcap 的 invalidstartdir 规则会连注释一起扫，所以上面刻意用「PKGBUILD 所在目录」
# 而不是 makepkg 那个起始目录变量名——写了字面量就会被报成 "File referenced in ..."，
# 让 namcap 出假阳性。精确写法见 scripts/pkgbuild-dir.sh 的注释。
#
# 硬性前提：pnpm >= 11。仓库声明 packageManager: pnpm@11.7.0，pnpm 11 会自己切到该版本；
# pnpm 9 会报 ERR_PNPM_LOCKFILE_CONFIG_MISMATCH。

pkgname=dsh-desktop-linux
pkgver=0.2.1alpha2
pkgrel=1
_tag='dsh-v0.2.1-alpha.2'
_commit='d743267388641bc76f17c45ce8b4c231aed1d32c'
# GitHub 源码包的顶层目录名 = <repo>-<tag>，tag 自带的 "v" 不剥（实测 dsh-v0.2.1-alpha.1）
_srcdirname="deepseek-harness-$_tag"

pkgdesc='Official DeepSeek Harness desktop application (Electron shell around a bundled dsh runtime)'
arch=('x86_64')
url='https://github.com/ffyfox/dsh-desktop-linux'
license=('MIT')
# 上游 deb/rpm 的 control 里声明的运行时依赖，换成 Arch 的包名，再加上 ldd 显示而
# Debian 那边由传递依赖带来的 alsa-lib / dbus。剩下的（cairo、pango、libx11、libcups、
# libgbm、libxkbcommon、at-spi2-core、libepoxy、wayland …）都由 gtk3 拉进来——实测
# `pactree -u gtk3` 含 mesa，包级别 namcap 对这些一条也没报。
# libxcrypt-compat 是唯一落在 gtk3 闭包外的：捆绑 Python 里那个已废弃的 _crypt 模块链接
# libcrypt.so.1，而 glibc 2.38 之后这个 soname 由 libxcrypt-compat 提供。namcap 会报它。
# libdbusmenu-glib 同理是 namcap 看不见的一项，但成因不同：它不是 ELF 依赖而是 dlopen 的。
# Electron 的 Linux 托盘走进程内 StatusNotifierItem（二进制里没有 appindicator 字样，
# ldd/NEEDED 里也没有），图标本身不需要 libappindicator；但托盘菜单要靠
# libdbusmenu-glib.so.4 才能导出（二进制里有这个库名和 dbusmenu_* 符号名，却不在 NEEDED 里）。
# 缺了它，托盘图标还在、右键菜单是空的——等于没有退出入口。
depends=('gtk3' 'nss' 'libnotify' 'libxss' 'libxtst' 'xdg-utils' 'at-spi2-core'
         'libsecret' 'alsa-lib' 'dbus' 'libxcrypt-compat' 'libdbusmenu-glib')
# python 是 node-gyp 的后备：正常情况下 node-pty / sharp / koffi / native-system 都命中预编译
# 产物（实测这次构建没有编译任何东西），但预编译缺失时 pnpm install 会退回源码编译。
# 其余构建工具（patch、bsdtar、make、gcc）由 makepkg 假定存在的 base-devel 提供。
makedepends=('nodejs' 'pnpm' 'python')
# 与 AUR 上同上游的 deepseek-harness-desktop 撞一个文件：
# /usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg。pacman 遇到同名文件会直接拒装，
# 声明冲突让它先提示卸掉对方；本机从旧包名升上来也走这条路。
conflicts=('deepseek-harness-desktop')
options=('!strip' '!debug' '!emptydirs')
install="$pkgname.install"

source=("$pkgname-$pkgver.tar.gz::https://github.com/deepseek-ai/deepseek-harness/archive/refs/tags/$_tag.tar.gz"
        # 补丁必须平铺（见文件头说明），顺序即文件名顺序
        '0001-desktop-target-model-add-linux-x64.patch'
        '0002-package-target-add-linux-x64.patch'
        '0003-electron-builder-linux-configuration.patch'
        '0004-prepare-target-electron-distribution.patch'
        '0005-desktop-linux-release-settings.patch'
        '0006-desktop-package-linux-scripts.patch'
        '0007-tests-linux-x64-supported.patch'
        '0008-desktop-host-runtime-standalone-node.patch'
        '0009-desktop-packaging-host-runtime.patch'
        '0010-desktop-linux-policy-opt-out.patch'
        '0011-desktop-linux-package-metadata.patch'
        '0012-desktop-build-commit-release-archive.patch'
        '0013-desktop-linux-tray.patch'
        '0015-desktop-linux-hidden-overlay-reveal.patch'
        # 0016–0018 是叠加在 0001–0015 之上的（要改的文件已被前面的补丁动过），
        # 所以必须在它们之后应用。见 patches/README.md。
        '0016-desktop-linux-appimage-update-feed.patch'
        '0017-desktop-linux-runtime-update-feed-override.patch'
        '0018-desktop-linux-window-caption.patch'
        # 0019 独立于前面所有补丁（只改 desktop-host/src/cli.ts），放最后不影响顺序。
        '0019-desktop-host-cli-unpacked-support-dir.patch'
        # 补丁系列是文本 diff，装不下托盘 PNG —— GNU patch（makepkg 与 PKGBUILD 都用它）
        # 不支持 git 的二进制补丁。所以这张图作为普通本地 source 平铺过来，由 prepare() 放进源码树。
        'tray-linux.png')
sha256sums=('f54cf0530ffba0ffb6bd00d08d5459918a1518cb77b22aa2b166a5dba234428a'
            '67a38b25575b2e4f3075eb0a516636db22795895eacf5ae9b6f3c13693a22f23'
            '4989a5cf20ac3c4ab927e7693dd62050f55e51b8e567ea74faa85585a40fe4c7'
            '1ce9a46d880e716b81fef582017f2df098e61ed2940a4530b81dc0ba1d52b5bb'
            '516d056bb384fa6bdae4095e5ca55483644e82fd39af72c7b4889e44b220ed3d'
            '54b1513b684871e138be34599c7db0ca9ed80baf13c8c264d869834ab9bde9f3'
            '188c28b94fdd829f6d8cf8748d19d0d152cf9144ef8f3c51c2e5fd651a34507a'
            'b78a49f2ca34679f78aad141f3d99ee74bec205b60d19b26fe9a1f0e69f88f2b'
            '560c968e3af27ceff604906222492dff40ef4fbfa8e78966789710ef2fd3c154'
            '04164750453341d2d76e10facd05203c7e44967a2ccc055f0c9d629703e5100a'
            '062567a5bcd5f4d8e63368a98927055358318f428c88fb851846d64fb859db8e'
            'a3ff4a524a4ebe28551797bd36dab7b7139516e668462f054e616e8a521e3e8f'
            'd19ea9f506e2d0356a926ad2d20d67bab60511139fafb4e12f338d4d41739715'
            '042117088d416a602985e595e768b2d921e98b64477eaa6a04383a958ae79ba3'
            '9496d3d4c4c9741a396c940bd0babd97e1d58111da31ba746cf0a6061825adba'
            'fafd11d15cb013b4a83fc3bd6b170fe83f34ea9bd962bba903e617577cd5e9a1'
            '6567d07a59ba7c40a8a650112e1d3cffd655bae320ba1682cce74cdc43d813a2'
            'cb813b65e76920141c7cc3bd17a27612621e81ef4012c74f9b60ce5616d52c88'
            '40a31a1dabbd9c2453c701b57d99461476c6de9296ea2119f32855a39e613e76'
            'd1153ab7bb1c61ca7f6568b4525f6c3f3c7bf9a9e29af1697f3c02da7dee5322')

prepare() {
  cd "$srcdir"

  # makepkg 只在成功后才清 $srcdir。失败重跑时它会重新解包源码包，把补丁改过的文件恢复
  # 原状，却留下补丁新增的文件（0005 的 .env.linux.example）—— 于是 0005 变成「一半已
  # 应用」，正向反向都打不上。直接从源码包重建工作树，prepare() 就可以反复执行。
  rm -rf "$_srcdirname"
  bsdtar -xf "$srcdir/$pkgname-$pkgver.tar.gz" -C "$srcdir"
  cd "$_srcdirname"

  # 0001–0015 相对同一个基线（$_tag）生成、互相独立；0016/0017 叠加在其上，所以按文件名
  # 顺序应用即可（顺序在这里是有意义的，不能重排）。
  local patchfile
  for patchfile in "${source[@]}"; do
    [[ "$patchfile" == *.patch ]] || continue
    msg2 "applying $(basename "$patchfile")"
    patch -Np1 -i "$srcdir/$(basename "$patchfile")" || return 1
  done

  # 托盘 PNG 落进上游的资源目录（为什么不做成补丁见 source 里的说明）。补丁 0013 让 Linux 的
  # 托盘指向 resources/tray-linux.png，electron-builder 再把它拷进产物的 resources/。
  # 这张图由上游自己的渲染器生成：apps/desktop 里跑 `pnpm run render:tray-icon`（补丁 0013
  # 让该脚本除了 ICO 之外也输出这张 PNG），然后拷进仓库的 assets/。
  install -Dm644 "$srcdir/tray-linux.png" apps/desktop/resources/tray-linux.png
}

build() {
  cd "$_srcdirname"

  # 隔离的 dsh 数据目录：构建期 Host 会往这里写东西，绝不能落到用户真实的 ~/.dsh。
  export DSH_HOME="$srcdir/dsh-home"

  # 上游平时从 git checkout 读这两个值（scripts/client-build-environment.ts 的
  # repositoryCommitHash、apps/desktop/scripts/desktop-build-commit.mjs 的
  # readDesktopBuildCommit）。release 源码包里没有 .git，所以显式给出；补丁 0012 让
  # 后者在不是 checkout 时接受环境变量。dirty=1 是事实：这个构建确实打了补丁。
  export DSH_CLIENT_COMMIT_HASH="$_commit"
  export DSH_DESKTOP_BUILD_COMMIT="$_commit"
  export DSH_DESKTOP_BUILD_DIRTY=1

  local pnpm_version
  pnpm_version="$(pnpm --version)"
  if (( ${pnpm_version%%.*} < 11 )); then
    error "需要 pnpm 11 或更新版本，当前是 $pnpm_version（上游声明 packageManager: pnpm@11.7.0；pnpm 9 会报 ERR_PNPM_LOCKFILE_CONFIG_MISMATCH）"
    return 1
  fi

  # Linux 发布设置：APP_ID 必填。MAINTAINER/HOMEPAGE 只在打 deb/rpm 时要（fpm 的 control
  # 缺这两项会拒收），本包只出未打包目录，所以不需要。
  # 强制更新策略通道是 Windows/macOS 专有的：Linux 产物没有更新通道，所以不嵌入策略、不轮询，
  # 上游要求必填的 *_ORIGIN 在这里用不到。
  cat > apps/desktop/.env.linux <<EOF
DSH_DESKTOP_APP_ID=com.deepseek.harness
EOF

  # 发布设置只能来自文件（环境里的同名变量会被 desktop-package-environment 剥掉），所以要让
  # 构建期内部的 pnpm 走镜像源、必须写进 .env.linux。打包者用环境变量传入，不传则保持上游默认
  # （registry.npmjs.org —— 本机实测单条请求要 30–40 秒，payload 安装会直接超时失败）：
  #   DSH_DESKTOP_NPM_REGISTRY=https://registry.npmmirror.com makepkg -C -s --nocheck
  if [[ -n "${DSH_DESKTOP_NPM_REGISTRY:-}" ]]; then
    printf 'DSH_DESKTOP_NPM_REGISTRY=%s\n' "$DSH_DESKTOP_NPM_REGISTRY" >> apps/desktop/.env.linux
  fi

  pnpm install --frozen-lockfile

  # 可选：复用一份已有的打包流水线下载缓存。流水线自己的缓存是树内的
  # apps/desktop/.desktop-build/downloads/（键 = 资产内容的 sha256，Electron 那条是下载 URL 的
  # sha256），而 makepkg 每次从源码包重建这棵树，所以默认每次都要重下 Electron（~117MB）与
  # primary-runtime 的 Node/Python/wheels（~110MB）。指向一份已有的 downloads 目录即可跳过：
  #   DSH_DESKTOP_LINUX_DOWNLOAD_CACHE=/path/to/.desktop-build/downloads makepkg -C -s --nocheck
  # 不设这个变量时行为完全不变；设了也只是 cp -n，绝不覆盖已有文件。
  if [[ -n "${DSH_DESKTOP_LINUX_DOWNLOAD_CACHE:-}" ]]; then
    install -d apps/desktop/.desktop-build/downloads
    cp -an "$DSH_DESKTOP_LINUX_DOWNLOAD_CACHE/." apps/desktop/.desktop-build/downloads/
  fi

  # Electron 二进制（~117MB）平时由 require('electron') 首次自动下载到 ~/.cache/electron。
  # 这里显式预热一次，让下载失败发生在构建前，而不是打包流水线中途。
  #
  # 注意：@electron/get 即使在缓存命中时也会回源拉同源的 SHASUMS256.txt 校验，所以要打到
  # GitHub releases 的网络不通（实测 curl 直连/代理都超时）时这一步会以 `TypeError: fetch failed`
  # 失败。此时在 makepkg 前加一个镜像变量即可，缓存键随 URL 变、命中后只多拉那份 6.7KB 清单：
  #   ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ makepkg -C -s --nocheck
  # 该镜像的清单与 GitHub 官方那份逐字节相同，CI（GitHub runner）不需要这个变量。
  node apps/desktop/node_modules/electron/install.js

  # 只要未打包目录：Arch 包直接把 linux-unpacked 装进 /opt，不需要再套一层 AppImage/deb/rpm。
  pnpm --dir apps/desktop run package:linux:x64:dir
}

package() {
  cd "$_srcdirname"

  local unpacked="apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked"
  if [[ ! -d "$unpacked" ]]; then
    error "找不到 $unpacked，构建产物路径可能变了"
    return 1
  fi

  install -d "$pkgdir/opt/deepseek-harness-desktop"
  cp -a "$unpacked"/. "$pkgdir/opt/deepseek-harness-desktop/"

  # 可执行文件名由上游 linux.executableName 决定（补丁 0003），是 deepseek-harness。
  install -d "$pkgdir/usr/bin"
  ln -s /opt/deepseek-harness-desktop/deepseek-harness "$pkgdir/usr/bin/deepseek-harness"

  # .desktop 照上游 deb/rpm 里 electron-builder 生成的那一份写，只改安装前缀。
  install -d "$pkgdir/usr/share/applications"
  cat > "$pkgdir/usr/share/applications/deepseek-harness.desktop" <<'EOF'
[Desktop Entry]
Name=DeepSeek Harness
Exec="/opt/deepseek-harness-desktop/deepseek-harness" %U
Terminal=false
Type=Application
Icon=deepseek-harness
StartupWMClass=deepseek-harness
Comment=Electron desktop shell for a bundled dsh runtime and external plugins
MimeType=x-scheme-handler/dsh;
Categories=Development;
EOF

  install -Dm644 apps/desktop/resources/icon-macos.svg \
    "$pkgdir/usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg"

  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"

  # 上游的 AppArmor profile 是 fpm 的 deb/rpm target 写进 linux-unpacked 的
  # （FpmTarget 里 copyFile(scripts.appArmor, resourceDir/apparmor-profile)），--dir 构建
  # 没有这个文件。这里照上游模板写一份，路径换成我们的安装前缀。Arch 默认不开 AppArmor，
  # 未启用时这个文件是惰性的；加载交给 .install。
  install -d "$pkgdir/etc/apparmor.d"
  cat > "$pkgdir/etc/apparmor.d/deepseek-harness" <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile "deepseek-harness" "/opt/deepseek-harness-desktop/deepseek-harness" flags=(unconfined) {
  userns,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/deepseek-harness>
}
EOF

  # setuid 位由 .install 按内核是否支持非特权 user namespace 决定，与上游 postinst 一致。
  chmod 0755 "$pkgdir/opt/deepseek-harness-desktop/chrome-sandbox"
}
