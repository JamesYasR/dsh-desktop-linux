# 补丁

按文件名顺序应用（见 `scripts/apply-patches.sh`），全部相对上游 `5badb15`（tag `dsh-v0.2.1-alpha.1`）。

组织约定：**一个文件只属于一个补丁**。每个补丁都是相对同一个基线的独立 diff，
互不重叠，因此应用顺序无关（仍按编号执行）。补丁由 `git diff -- <files>` 从开发工作树生成；
两个补丁共用一个文件时（`electron-builder-config.mjs` 属 0003 与 0013，`src/main.ts` 属 0008 与 0013），
必须按「基线 + 只有这一个补丁」的隔离树取 diff，否则会把另一个补丁的 hunk 一起带进来。

已验证（0.2.1-alpha.1）：15 个补丁按序打在完整的上游 release 源码包（tag `dsh-v0.2.1-alpha.1`）上，
`patch -Np1`（makepkg 的 `prepare()`）与 `git apply`（`apply-patches.sh` / CI）都干净通过，
49 个触及文件（44 个改动 + 5 个新增）与开发工作树逐字节一致；源码包本身也与 git 对象核对过
（14194 个文件逐字节一致）。`pnpm install --frozen-lockfile` 与整条打包流水线在这棵树上通过，
`build.sh --all` 出齐 AppImage/deb/rpm（0.2.1-alpha.1，electron 44.4.5），`makepkg` 也整包构建成功
（`dsh-desktop-linux-0.2.1alpha1-1`，25921 个文件）；产物里 `resources/runtime/cli` 不存在，
正是 0004 的 Linux 闸门在起作用。
rc.2 → 0.2.1-alpha.1 只有 3 个文件变过（`pnpm-lock.yaml`、`apps/desktop-host/src/index.ts`、
`apps/desktop/package.json`），对应 0006 / 0008 / 0014 三个补丁重生，其余 12 个逐字节未动。

## 让 Linux 成为受支持的 target（0001–0007）

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0001-desktop-target-model-add-linux-x64.patch` | `desktop-build-paths.{mjs,d.mts}`、`desktop-auto-update-environment.{mjs,d.mts}` | target 白名单加 `linux-x64`；`desktopTargetPlatform` 返回 `'linux'`；新增 `desktopElectronExecutablePath()` |
| `0002-package-target-add-linux-x64.patch` | `package-target.ts`、`desktop-upload-plan.ts` | 打包目标表加 `linux-x64`；Linux 构建主机校验；放宽 `--unsigned` |
| `0003-electron-builder-linux-configuration.patch` | `electron-builder-config.mjs` | 允许 unsigned 的 Linux 构建；Linux 关闭 asar；显式 `executableName`；Linux 不嵌入强制更新策略；Linux 的打包格式与包元数据来自发布设置（见 `0011`）；显式钉住 deb/rpm 的 `packageName` / `packageCategory` 与 `linux.synopsis`；用 `appImage.executableArgs: []` 去掉 legacy 工具集写死的 `--no-sandbox`；Linux 图标显式指定为 SVG —— 单个 PNG 文件会被 electron-builder **原样按自身像素尺寸**装进 `hicolor/1024x1024/apps`，而多个发行版的 `hicolor/index.theme` 并不声明该目录（Arch 就没有），图标会解析不到；SVG 落到 `hicolor/scalable/apps`，所有发行版都声明 |
| `0004-prepare-target-electron-distribution.patch` | `prepare-dsh.ts`、`prepare-runtime.ts` | Electron 分发路径按 target 推导，不再假设「非 mac 即 win32」；打包期 `pnpm install` / 运行时冒烟改用 Host 运行时；`versions.json.node` 记为 payload 实际运行的 Node 版本；Linux 上整块跳过 rc.2 新增的 `prepare:cli`（见「注意」） |
| `0005-desktop-linux-release-settings.patch` | `desktop-package-environment.{mjs,d.mts}`、`desktop-toolchain-preflight.ts`、`.gitignore`、`.env.linux.example`、`tests/desktop-package-environment.spec.ts` | 支持 `.env.linux`；Linux 不套用 Windows/macOS 专属设置；Linux 不要求策略 origin；修掉 `win32 ? … : macOS` 的隐含假设；Linux 文件白名单加 `MAINTAINER`/`HOMEPAGE`（并从环境里剥掉，保证发布设置只由文件拥有）；打了 rpm 才预检 `rpmbuild` |
| `0006-desktop-package-linux-scripts.patch` | `apps/desktop/package.json` | `package:linux:x64` / `package:linux:x64:dir` |
| `0007-tests-linux-x64-supported.patch` | 3 个 `tests/*.spec.ts` | 把「断言 Linux 抛错」改成「断言 Linux 受支持」 |

## 让 Host 跑在真 Node 上（0008–0010）

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0008-desktop-host-runtime-standalone-node.patch` | `src/node-environment.ts`、`src/host-process.ts`、`src/main.ts`、`desktop-host/src/index.ts`、`scripts/node-bin/node`、4 个 spec | 引入 `DesktopNodeRuntime`；Linux 上 Host 走 primary-runtime 的真 Node；`ELECTRON_RUN_AS_NODE` 只在真 Electron 运行时下设置 |
| `0009-desktop-packaging-host-runtime.patch` | `scripts/dev.ts`、`scripts/smoke-{runtime,prepared-runtime,packaged-runtime}.ts`、`scripts/sign-primary-runtime.ts`、`tests/fixtures/runtime-payload-smoke.mjs`、`tests/prepared-runtime-smoke.spec.ts` | 把 Host 运行时贯穿 dev / 打包 / 冒烟；payload smoke 的 Electron 专属断言改为按平台判断 |
| `0010-desktop-linux-policy-opt-out.patch` | `desktop-policy-environment.{mjs,d.mts}`、`tests/desktop-policy-environment.spec.ts` | 新增 `desktopPlatformEmbedsPolicy()`：策略服务只认 `desktop-win` / `desktop-mac`，Linux 不参与 |

## 产物与包元数据（0011–0012）

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0011-desktop-linux-package-metadata.patch` | `desktop-linux-packages.{mjs,d.mts}`、`tests/desktop-linux-packages.spec.ts` | 新增 `resolveDesktopLinuxFormats()`（`DSH_DESKTOP_TARGET_FORMATS`，缺省只出 AppImage）与 `resolveDesktopLinuxPackageMetadata()`（deb/rpm 必须给 `Name <email>` 形式的 maintainer 和绝对 http(s) homepage，两者一起报错） |
| `0012-desktop-build-commit-release-archive.patch` | `desktop-build-commit.mjs`、`tests/desktop-build-commit.spec.ts` | `readDesktopBuildCommit()` 在目录不是 git checkout 时读 `DSH_DESKTOP_BUILD_COMMIT` / `_DIRTY`，两者都没有才报错。上游从 checkout 构建，distro 打包从 release 源码包构建，后者没有 `.git` |

`0003` 消费 `0011`，`0005` 也消费 `0011`：格式选择和包元数据的**规则**只有一份（`0011`），
`0003` 拿去配 electron-builder，`0005` 拿去做打包最前面的预检。按「一个文件只属于一个补丁」，
规则本身单独成一个补丁。

## 让 Linux 也有托盘（0013–0014）

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0013-desktop-linux-tray.patch` | `src/main.ts`、`src/tray.ts`、`src/background-notice.ts`、`scripts/electron-builder-config.mjs`、`scripts/render-tray-icon.ts` | 托盘的创建条件从只认 `win32` 放宽到 `win32 \|\| linux`；Linux 的托盘图是 `resources/tray-linux.png`（单张 PNG，托盘宿主自己缩放到面板；**用应用图标自身的留白，不做 Windows 那 20% 放大**，见「注意」）；首次关窗的一次性提示同样覆盖 Linux —— 它的文案本来就是「可在系统托盘中重新打开窗口」，在 Linux 上这句话只有有了托盘才成立；渲染器除 ICO 之外也输出那张 PNG；electron-builder 的 Linux `extraResources` 把它带进产物的 `resources/` |
| `0014-electron-version-tray-fix.patch` | `pnpm-lock.yaml` | 把 lockfile 里 electron 的解析从 `44.0.0` 提到 `44.4.5`。上游 `apps/desktop/package.json` 本来就写 `^44.0.0`（caret 就允许 44.4.5），只是 lockfile 把解析钉在 44.0.0 —— 而那个版本的 Linux 托盘在 KDE 与 GNOME 下都注册不上（上游回归，见「注意」）。改动只有 4 行：importer 的 `version`、`packages` 段的版本名与 integrity、`snapshots` 段的版本名；两个版本的依赖范围逐字相同，所以传递依赖一行都不用动 |

托盘 PNG 是二进制，`patches/` 装不下：makepkg 用的是 GNU patch，它不支持 git 的二进制补丁。
所以这张图作为普通本地 `source` 走，仓库里存在 `assets/tray-linux.png`，由两条路径各自放进
`apps/desktop/resources/`：PKGBUILD 的 `prepare()`（`makepkg` 路线）和 `scripts/apply-patches.sh`
（CI 与本地 `build.sh` 路线）。刷新它 = 在 `apps/desktop` 里跑 `pnpm run render:tray-icon`，
再把输出的 `resources/tray-linux.png` 拷进 `assets/`（图和 Windows 托盘同源，都是
`resources/icon-windows.svg`）。

## 让关窗提示在 Wayland 下真的显示出来（0015）

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0015-desktop-linux-hidden-overlay-reveal.patch` | `src/update-overlay.ts` | 提示浮层是 `transparent: true` + `show: false` 的子窗口，只在 `ready-to-show` 里 `show()`；而这种窗口在 Wayland 下不报告首帧，于是浮层建好了、内容也渲染对了，却始终 `isVisible() === false` —— 用户既看不到也点不到，关窗看起来像卡住。Linux 上再用 `did-finish-load` 兜一次 `reveal()`；Windows/macOS 的 `ready-to-show` 行为一字未动 |

`0015` 是 `0013` 的下游：Linux 的首次关窗提示是 `0013` 打开的，而它用的正是这个浮层。

## 让 Linux 也有应用内更新（0016–0017）

上游桌面端的内建更新走 `electron-updater` + generic provider，而 `UPDATE_TARGETS` 只认
mac/win，Linux 没有通道。更关键的是：**unsigned 构建直接跳过更新配置**（`publish` 为 null），
所以 Linux 产物连 `app-update.yml` 都不存在，更新器默认是关的。这两个补丁把 Linux 的
AppImage 更新通道接通，细节见 [docs/updates.md](../docs/updates.md)。

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0016-desktop-linux-appimage-update-feed.patch` | `scripts/desktop-linux-update.{mjs,d.mts}`（新增）、`scripts/desktop-package-environment.mjs`、`scripts/electron-builder-config.mjs`、`.env.linux.example` | 新增 `resolveDesktopLinuxUpdateConfig()`：读 `DSH_DESKTOP_LINUX_UPDATE_ORIGIN`，校验后交给 electron-builder 的 `publish`。**只在 unsigned 的 Linux 构建上生效**，让产物产出 `app-update.yml` 与 `nightly-linux.yml`；不设则维持上游行为（`publish: null`，无更新器）。地址必须是绝对 URL、HTTPS（或回环上的 HTTP），不带凭据/query/fragment；`.env.linux` 白名单加上这个键，打包前先校验，坏地址在准备阶段就报错而不是打包末段 |
| `0017-desktop-linux-runtime-update-feed-override.patch` | `src/update-coordinator.ts` | 同一个环境变量在**启动时**覆盖 embed 的 feed（`updater.setFeedURL(...)`），并让 `enabled()` 在 override 存在时也成立。效果：一个 AppImage 可以指向任意 feed —— 本地验证不必为换地址重编，运维换托管也不必重发产物。变量只在这一处读取，未设时行为与上游一致 |

### 与 0001–0015 不同的地方

**`0016` / `0017` 的基线是「已应用 0001–0015 的树」，不是上游 `5badb15`。** 前 15 个补丁相对
同一个干净基线、彼此不重叠；这两个是叠加在其上的，因为 `0016` 要改的
`desktop-package-environment.mjs`、`electron-builder-config.mjs`、`.env.linux.example` 正是
`0003` / `0005` 已经改过的文件。按文件名顺序应用（`apply-patches.sh` 与 PKGBUILD 都是这个顺序），
`0016` / `0017` 会最后落上去；`--revert` 逆序撤销也成立。

重做上游基线时：先重生成 0001–0015（ffyfox 的流程），再在这棵树上重新生成这两个。

### 注意

- **通道名是 `nightly`，不是 `latest`。** `src/update-coordinator.ts` 里写死
  `updater.channel = 'nightly'`，所以 electron-builder 产出的元数据文件叫
  `nightly-linux.yml`，而**不是**它默认的 `latest-linux.yml`。发布时必须按这个名字提供。
- **`0016` 只管构建期，`0017` 只管运行期。** 前者决定产物里嵌不嵌 feed、嵌什么地址；
  后者决定启动时要不要换成别的地址。不设变量时两者都不改变上游行为。
- **AppImage 才装得上更新。** electron-updater 在 Linux 选 `AppImageUpdater`，安装时要用
  `$APPIMAGE` 定位并替换正在运行的那个文件；从 `linux-unpacked` 目录直接跑没有这个变量，
  检查可以走通但安装会以 `ERR_UPDATER_OLD_FILE_NOT_FOUND` 失败。deb / rpm 装出来的那份不走这条路。
- **产物是 unsigned 的，更新只校验 sha512，没有签名校验。** feed 的信任边界就是「谁能写它」，
  所以公网 feed 必须由发布者自己控制的 HTTPS 源。

## 让 Linux 用上跨平台标题栏（0018）

上游只给 Windows 的主窗口设了 `titleBarStyle: 'hidden'` + `titleBarOverlay`，Linux 落回 GTK 的
原生标题栏**加**应用菜单栏。实测（Electron 44.4.5，Ubuntu 26.04 / GNOME 50 / Wayland）：
默认窗口的非客户区是 **110px**，`titleBarStyle: 'hidden'` 之后只剩 **42px**（Wayland 的阴影外扩），
说明那一条正是 GTK 画出来的。

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0018-desktop-linux-window-caption.patch` | `src/linux-window.ts`（新增）、`src/linux-caption.ts`（新增）、`tests/linux-window.spec.ts`（新增）、`src/main.ts`、`src/ipc.ts`、`src/preload-app.ts`、`src/preload-windows.ts`、`src/locale.ts` | 新增 `DSH_DESKTOP_LINUX_WINDOW_CHROME`，取值 `caption`（默认）/ `native` / `rounded`。`caption` 让 Linux 主窗口走与 Windows 同一条自定义标题栏路径：Web 客户端按 `data-windows-titlebar` 预留 40px 标题条，Application/Edit 走原生弹出菜单，窗口按钮由 Electron 的 window-controls overlay 画；`native` 保留上游行为；`rounded` 走无边框透明窗口、自绘按钮与 12px 圆角 |

### 三种模式

| 模式 | 窗口 | 按钮 | 圆角 | 说明 |
|---|---|---|---|---|
| `caption`（默认） | `titleBarStyle: 'hidden'` + `titleBarOverlay` | Electron overlay 绘制的系统风格按钮 | 由 GNOME 决定（上圆下直） | 与 Windows 版一致的跨平台标题条 |
| `rounded` | `frame: false` + `transparent: true` | 页面自绘（含本地化 aria-label） | 四角 12px | 实验性，见下 |
| `native` | GTK 原生标题栏 + 菜单栏 | 系统 | 系统 | 上游原始行为，回退用 |

### 注意

- **overlay 只在非透明窗口上可用（实测）。** `titleBarOverlay` 与 `transparent: true` 互斥：
  `hidden` + overlay 时 `navigator.windowControlsOverlay.visible === true`（rect 高 40px）；
  一旦加 `transparent`，`visible` 变 `false`、非客户区归零。所以「系统风格按钮」与「四角圆角」
  在当前 Electron 上只能二选一，默认选了前者。
- **`rounded` 的透明有实测疑点，所以不是默认值。** X11 下窗口确实是 32 位 ARGB 视觉
  （`Depth: 32`），CSS 的 `border-radius` 也确认生效（`getComputedStyle` 读到 60px），
  但抓到的窗口像素在圆角处 alpha 仍是 1；补上 `enable-transparent-visuals` 也一样。
  Wayland 下未验证。想要四角圆角的话先手工试：
  `DSH_DESKTOP_LINUX_WINDOW_CHROME=rounded ./deepseek-harness-*.AppImage`。
- **只剩 40px 就意味着原生菜单栏没了。** 上游 Linux 的应用菜单（Application/Edit）来自
  `Menu.setApplicationMenu`，它以窗口内菜单栏的形式占高度。`caption` / `rounded` 下这条菜单
  改为页面内的弹出菜单（`installWindowsMenu`，与 Windows 同源），所以 `refreshApplicationMenu`
  与 `windowsMenu` IPC 的门禁从「仅 win32」放宽到「所有标题栏平台」。
- **`data-windows-titlebar` 这个属性名没改。** 它由 Web 客户端的 `ui-layout` 消费
  （`AppFrame.module.css`），Linux 复用同一套布局。改名要动客户端包，收益只是好看，
  所以这里沿用原名并在 `preload-windows.ts` 里注明它现在的含义是「标题栏平台」。

## 注意

- **dev 模式也需要 `0001`**——`dev.ts` 虽然不走 `package-target.ts`，
  但会调用 `resolveDesktopBuildTarget()`，Linux 上抛 `unsupported target linux-x64`。
- 上游有手写的 `.d.mts` 声明文件，改 `.mjs` 的 JSDoc **不够**，类型联合必须同步改 `.d.mts`，
  否则 `tsc` 报错。
- **`DSH_DESKTOP_NODE_ELECTRON` 的缺省值必须保持「Electron」**。调用方清空环境时不会带上
  这个变量，缺省若回落到 standalone，macOS / Windows 的包脚本会以 GUI 模式起 Electron。
- `0003` 与 `0005` 都涉及策略：`0003` 决定「产物里嵌不嵌」，`0005` 决定「打包期要不要 origin」。
  一个文件只属于一个补丁，所以这两半分在两处。
- **`DSH_DESKTOP_TARGET_FORMATS` 刻意不进 `.env.linux` 白名单**。它是「这次构建打什么」的
  选择器（和 `DSH_DESKTOP_TARGET_PLATFORM` / `_ARCH` 同类），不是发布设置；进了文件反而会让
  `build.sh --deb` 被文件里的值盖掉。
- **`0012` 是唯一为「非 git 源码」存在的补丁**。上游两条路都要 git：`scripts/build.ts` 经
  `repositoryCommitHash()` 读 `HEAD`（有 `DSH_CLIENT_COMMIT_HASH` 环境变量出口，不用改），
  `package-target.ts:364` 无条件调 `readDesktopBuildCommit()`（没有出口，所以要 `0012`）。
  PKGBUILD 从 release 源码包构建，所以两个变量都由它显式给出，`_DIRTY=1` 也是事实——这个
  构建确实打了补丁。
- **rc.2 新增的 `prepare:cli` 在 Linux 上整块跳过（`0004`）。** `prepareDesktopCli(dir, platform)` 的
  形参是 `'darwin' | 'win32'`（不含 `linux`），它拷的 `apps/desktop/cli/dsh` 是 macOS 脚本
  （内部 exec `$resources/../MacOS/DeepSeek Harness`），`link-entry` 要 clang 编译，
  `command-manager-entry.js` 走 `/usr/local/bin/dsh` 与 PowerShell；而 rc.2 里触发这套东西的菜单项
  本身就 gate 在 `darwin` / `win32`。Linux 上没有入口，硬跑还会把 macOS 启动器塞进产物，
  所以这一段包进 `if (platform !== 'linux')`，Linux 不产出 `runtime/cli`。
- **`0015` 的根因是量出来的，不是猜的。** 用 `--remote-debugging-port=9222 --inspect=9229` 起应用，
  从主进程读 `BrowserWindow.getAllWindows()`：关窗后浮层窗口存在、`modal: true`、内容与按钮位置都对，
  但 `isVisible()` 是 `false`；手动 `show()` 一次即正常显示且可用鼠标点。Debian 13（GNOME 48.7）与
  Ubuntu 26.04（GNOME 50.1）都如此，打上 `0015` 后两边都变成 `true`，鼠标点 Confirm 能写入 marker 并隐藏窗口。
  整个桌面端只有这一个窗口依赖 `ready-to-show`，所以只修这一处。
- **托盘的依赖问题全在 ELF 之外。** 实测（Electron 44 二进制）：Linux 托盘走进程内的
  StatusNotifierItem（二进制里有 `StatusIconLinuxDbus`、`org.kde.StatusNotifierWatcher`），
  全库没有 `appindicator` 字样，`ldd` / `NEEDED` 里也没有，所以**不需要** libappindicator。
  但托盘菜单要 `libdbusmenu-glib.so.4`——那个库名和 `dbusmenu_*` 符号名都在二进制里，
  却不在 `NEEDED` 里（1519 个未定义动态符号里没有它），即 dlopen。缺了它图标照出、菜单是空的，
  等于没有退出入口，而 `ldd` 和 namcap 都看不见，所以它由 PKGBUILD 显式写进 `depends`。
- **Linux 上可靠的是托盘菜单，不是单击图标。** 实测把 SNI 的 `Activate` 调过去，Electron 的
  `tray.on('click')` 没有触发（StatusNotifierItem 宿主有权把左键用来弹菜单）。`DesktopTray`
  保留 click 处理是给 Windows 的；Linux 上「打开」走右键菜单，`verify.sh --runtime` 也是按
  菜单里的条目来断言。
- **托盘美术在 Linux 上刻意与 Windows 不同，Windows 那份一个字都没动。** 上游的 `tray-glyph`
  组只含鲸鱼（底在组外），渲染 Windows ICO 时会被绕方块中心放大 20% —— 因为 Windows 托盘逻辑
  尺寸是 16px，不放大就看不清。Linux 不同：托盘宿主按面板尺寸自己绘制（KDE 是 22px），1.2× 在
  那里会显得鲸鱼顶满方块。所以 `renderLinuxTrayIcon()` 按原比例渲（保留应用图标自身的留白，
  与启动器/任务栏图标观感一致），底图仍然保留，深浅面板都还有对比度。两边同源（都用
  `resources/icon-windows.svg`），改动只在渲染参数上。
