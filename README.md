# dsh-desktop-linux

**中文** | [English](README.en.md)

> 本项目为独立社区项目。**不是** DeepSeek 官方产品，与 DeepSeek 无隶属关系。

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 官方桌面端
（`apps/desktop` 的 Electron 应用）的**打包流水线**移植到 Linux，产出
AppImage / deb / rpm / Arch 包。

上游目前明确不支持 Linux（`apps/desktop/README.md`：*"Linux is not a supported Desktop
release target."*）。本项目补的就是这一块：让官方打包流水线认得 `linux-x64` 并产出安装包。
当前验证范围见[验证状态](#验证状态)。

![DeepSeek Harness 桌面端界面](docs/screenshot.png)

## 项目产物

本项目的产物是**官方 Electron 应用本身**：

- 渲染走自己的 `dsh-app://` 协议，而不是去连一个本地 Web 服务；
- 内置 Node / pnpm / Python 运行时，不依赖系统 Node；
- 独占 `$DSH_HOME/profiles/desktop`，不占用 `web` profile。

代价是构建重得多：要拉上游 monorepo、跑 pnpm workspace 构建、再用 electron-builder 打包。

## 安装

| 发行版 | 格式 | 安装方式 |
|---|---|---|
| 通用 | AppImage | 从 [Releases](https://github.com/ffyfox/dsh-desktop-linux/releases) 下载，`chmod +x` 后直接运行 |
| Debian / Ubuntu | deb | `sudo apt install ./deepseek-harness-*.deb` |
| Fedora / RHEL | rpm | `sudo dnf install ./deepseek-harness-*.rpm` |
| Arch Linux | AUR | `yay -S deepseek-harness-desktop`（或 `paru`） |

产物是 **unsigned** 构建（文件名里带 `-unsigned`）。安装后 `dsh://` 链接会交给它处理。

## 从源码构建

依赖：Node 22.19+ 或 24+、**pnpm 11**、git。
打 rpm 还需要系统有 `rpmbuild`（Arch 上是 `rpm-tools`）。

```bash
git clone https://github.com/ffyfox/dsh-desktop-linux
cd dsh-desktop-linux

./scripts/fetch-upstream.sh      # 拉上游源码（默认用 PKGBUILD 里钉的 tag）
./scripts/apply-patches.sh       # 打补丁
./scripts/build.sh --all         # AppImage + deb + rpm
./scripts/verify.sh --runtime    # 验证矩阵
```

`build.sh` 的参数：`--dir`（只出未打包目录，最快）、`--appimage`（默认）、`--deb`、`--rpm`、`--all`。
整条流水线（`build:official` → `release:pack` → `prepare:*` → `package`）才是耗时大头，
多打一种格式只多一次 fpm/AppImage 打包，所以分开跑更快，也更容易定位失败。

产物落在 `upstream/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/`。

deb / rpm 的 `Maintainer:` / `Homepage:` 来自 `upstream/apps/desktop/.env.linux`。`build.sh`
首次运行就从仓库里的 `.env.linux.example` 生成，值已经填好。要换成你自己的，改那个文件即可：
**同名环境变量会被上游整个滤掉**，`DSH_DESKTOP_LINUX_MAINTAINER=… build.sh --deb` 静默无效。

### 硬性前提

**必须用 pnpm 11。** 上游仓库声明 `packageManager: pnpm@11.7.0`，pnpm 11 会自己切到该版本；
pnpm 9 会在 `pnpm install` 报 `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`。

## Arch 包

PKGBUILD 直接吃上游的 release 源码包，不依赖 `./upstream` 检出：

```bash
./scripts/aur-dir.sh     # 摊平成 ./aur，并生成 .SRCINFO
cd aur && makepkg -si
```

`aur-dir.sh` 不是可有可无的糖：**makepkg 只在 PKGBUILD 所在目录里按 basename 找本地 source**，
所以 PKGBUILD 与补丁必须平铺在一起。`./aur` 里的内容就是可以直接提交给 AUR 的形态。

Arch 包只出未打包目录装进 `/opt/deepseek-harness-desktop`，`/usr/bin/deepseek-harness` 是符号链接——
Arch 上不需要再套一层 AppImage/deb/rpm。

## 它是怎么工作的

```
官方 Electron 壳（apps/desktop）
├── 渲染进程 ──── dsh-app:// 协议 ──── 应用 UI
└── Host 进程 ─── primary-runtime 自带的真 Node ─── 捆绑的 dsh 运行时
                       └── $DSH_HOME/profiles/desktop
```

三个值得知道的设计点：

- **Host 跑在真 Node 上，不是 Electron 的 node 模式。** Electron 的 node 模式下 `sharp` 解码会段错误，
  所以 Linux 的 Host 改走 primary-runtime 自带的 Node。连带地，**Linux 产物的 dsh 目录树不放进 asar**
  （真 Node 读不了归档），这是 `linux-unpacked` 体积偏大的原因。
- **profile 是独占的。** 桌面端用 `$DSH_HOME/profiles/desktop`，CLI 连参数层面都拒绝这个 profile
  （`error: profile "desktop" is managed exclusively by the Electron application`）。
  会话、设置、凭据仍在 `$DSH_HOME` 根上，与 CLI 共享。
- **沙箱。** 内核支持非特权 user namespace 时走 namespace 沙箱（渲染进程在独立 user namespace + seccomp）；
  不支持才退回 setuid `chrome-sandbox`。AppImage 交给 AppRun 自己探测，deb / rpm / Arch 包在
  postinst 里做同样的判断。

## 验证状态

**目前只有单一实测环境，后续会尽可能拓展测试范围。** 下面两张表随反馈更新——欢迎在
[Issues](https://github.com/ffyfox/dsh-desktop-linux/issues) 报告你的结果，能用和不能用
都欢迎。

### 环境

| 环境 | 状态 |
|---|---|
| Arch Linux · KDE Plasma 6 · Wayland · x86_64 | **已实测**，正常 |
| X11（任意发行版 / 桌面环境） | 未验证 |
| 其他桌面环境（GNOME、Hyprland 等） | 未验证 |
| Debian / Ubuntu、Fedora / RHEL | 未验证 |
| aarch64 | 未构建、未验证 |

### 产物

| 产物 | 状态 |
|---|---|
| Arch 包 | **已实测**：`makepkg` → `pacman -U` 安装 → 启动、沙箱、卸载 |
| AppImage | **已实测**：构建并起窗口 |
| `linux-unpacked` | **已实测**：`verify.sh --runtime` 活体矩阵 |
| deb | 只核对过 control 字段，未在 Debian / Ubuntu 上安装运行 |
| rpm | 只核对过 `rpm -qip` 字段，未在 Fedora / RHEL 上安装运行 |

## 已知限制

- **没有自动更新。** 上游的强制更新策略通道只认 `desktop-win` / `desktop-mac` 客户端身份，
  Linux 产物也没有更新通道，所以 Linux 版不嵌入策略、不轮询、不会自己更新。
- **不签名。** 产物是 unsigned 构建。
- **Platform 侧会把 Linux 客户端认成 macOS。** 上游的客户端身份映射是
  `platform === 'win32' ? 'desktop-win' : 'desktop-mac'`，Linux 落到 `desktop-mac`。
  这是上游类型联合 `'darwin' | 'win32' | null` 的结果，不是本项目引入的；
  同一个请求里的 `device_model` 又是 `linux-x64`。
- **`linux-unpacked` 约 1.1G。** asar 关闭后是小文件目录树，AppImage 压成 squashfs 后 339M，
  但首次启动的文件读取比 asar 多。
- **只做 x86_64。**

## 许可

MIT
