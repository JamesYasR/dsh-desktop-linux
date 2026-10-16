# Linux 版的应用内更新

上游桌面端的内建更新走 `electron-updater` + generic provider，feed 固定在
`https://download.deepseek.com/dsh-desk/feeds/<target>/`，而 `UPDATE_TARGETS` 只认
`mac-arm64` / `mac-x64` / `win-x64`，Linux 没有通道。**本项目补上了 Linux 的通道**，
所以 Linux 产物也有可用的「检查更新 → 下载 → 重启安装」。

补丁分两半，各自管一件事：

| 补丁 | 作用 |
|---|---|
| `0016-desktop-linux-appimage-update-feed.patch` | **构建期**：`DSH_DESKTOP_LINUX_UPDATE_ORIGIN` 让 unsigned 的 Linux 构建也产出 `app-update.yml` 与通道元数据 |
| `0017-desktop-linux-runtime-update-feed-override.patch` | **运行期**：同一变量在启动时覆盖 embed 的 feed，一个 AppImage 可以指向任意 feed |

## 更新是怎么落地的

```
AppImage 启动
  └── 主进程 DesktopUpdateCoordinator（src/update-coordinator.ts）
        ├── 启动时异步检查一次，之后每 10 分钟 ±20% 抖动检查一次
        ├── 手动入口：菜单 Application → Check for Updates
        └── electron-updater 在 Linux 上选 AppImageUpdater
              ├── 检查：GET  <origin>/nightly-linux.yml
              ├── 下载：GET  <origin>/<AppImage>，按 yml 里的 sha512 校验
              └── 安装：把新文件搬到 $APPIMAGE 的位置并重启（需要有 APPIMAGE 环境变量，
                        也就是必须**以 AppImage 方式运行**；解包目录跑起来的是没有更新能力的）
```

通道名是 `nightly`，所以元数据文件名是 `nightly-linux.yml`，不是 electron-builder 默认的
`latest-linux.yml`；发布时两个名字都要对。上游 alpha.3 起通道不再写死在
`update-coordinator.ts` 里，而是打包时由 `publish.channel` 决定、并作为清单字段
`dshDesktopUpdateChannel` 嵌进产物（缺省仍是 `nightly`，见 `src/update-channel.ts`）。
我们的 Linux feed 解析器（`0016`）显式返回 `channel: 'nightly'`，让元数据文件名与应用内更新器的
通道始终对齐——上游改这段代码时最容易在这里静默失效，见
[patches/README.md](../patches/README.md) 的 alpha.2 → alpha.3 复盘。

## 配置 feed 地址

地址来自 `apps/desktop/.env.linux`（git-ignored，`build.sh` 首次运行从模板生成），
**同名环境变量会被上游整个滤掉**，只能写进这个文件：

```dotenv
DSH_DESKTOP_LINUX_UPDATE_ORIGIN=https://github.com/JamesYasR/dsh-desktop-linux/releases/download/linux-latest
```

规则：

- 必须是绝对 URL；**HTTPS**，或回环地址上的明文 HTTP（本地验证用）。
- 不能带账号密码、query、fragment；结尾斜杠会被去掉。
- **不写这一行 = 产物不嵌入任何更新通道**，`publish` 为 null，应用里不会出现可用更新源，
  `app-update.yml` 也不存在。这是默认值，也是最安全的默认值。

构建后可以用运行期覆盖在同一份产物上换 feed，不必重编：

```bash
DSH_DESKTOP_LINUX_UPDATE_ORIGIN=http://127.0.0.1:8899 ./deepseek-harness-*-unsigned.AppImage
```

## 发布端要有两个文件

`scripts/build.sh --appimage` 产出的目录里：

```
nightly-linux.yml                                        # 通道元数据，含 version / sha512 / path
deepseek-harness-<version>-linux-x86_64-unsigned.AppImage # 载荷
```

把这两个文件放到**同一个目录**下即可，任何静态 HTTP 服务都行。相对路径按 feed 根解析，
所以换版本时整个目录替换即可。

`.github/workflows/update-feed.yml` 就是干这件事的流水线：定时扫上游最新 tag，
打补丁、构建、把这两个文件发到本仓库一个滚动的 `linux-latest` release。

### 发布历史与回退（两处 release 各管一件事）

| release | 装什么 | 会不会被覆盖 |
|---|---|---|
| `linux-latest`（滚动） | `nightly-linux.yml` + **当前版本**的 AppImage/deb | 会：每次发布都清掉上一版遗留的资产，缩短 feed 不完整的窗口 |
| tag = 上游 ref（归档，如 `dsh-v0.2.1-alpha.4`） | 同一次构建的产物（含 yml） | **不会**：只追加，重发时新文件名带 `<日期>.<序号>`，旧产物原样留着 |

所以回退不再依赖「重新编译」：想退回哪一版，就去那一版的归档 release 下载 AppImage/deb。
`linux-latest` 只保证应用内更新读到当前版本，不承担历史。

**补发历史版本**（例如补上已经不在 feed 里的 `dsh-v0.2.1-alpha.2`）：在承载该版本补丁集的分支上手动触发
workflow，把 `publish_feed` 设为 `false`（或留空 —— 只要 `ref` 不是最新上游 tag 就自动不动 feed）。
这样只写归档 release，用户正在用的 feed 一动不动：

```bash
# ref=要补的上游 tag；publish_feed=false 只归档；build_number 可显式指定，重现当时的版本号
gh workflow run update-feed.yml --repo JamesYasR/dsh-desktop-linux --ref <补丁集所在分支> \
  -f ref=dsh-v0.2.1-alpha.2 -f publish_feed=false -f build_number=2
```

注意：**补丁集必须与那个上游版本匹配**。`patches/` 永远相对最新基线，所以补发旧版本要在「当时的补丁集」
所在的分支/tag 上触发；本仓库为此保留了 `archive/dsh-v0.2.1-alpha.2` 分支（内容 = 当时的补丁集 + 当前
workflow）。

已安装的应用即使装回旧版，只要 feed 还指向新版就会继续提示更新 —— 它不会自动降级
（`allowDowngrade = false`），不想要这次更新就别点。要彻底停掉升级提示，运行期把 feed 指到别处即可：

```bash
DSH_DESKTOP_LINUX_UPDATE_ORIGIN=http://127.0.0.1:8899 ./deepseek-harness-*.AppImage
```

### 应用内选择版本：自动检查开关与回退

这三个入口都在应用菜单「应用」里（各语言用各自本地化文案，位置与「检查更新…」同一列）：

| 菜单项 | 行为 | 偏好字段 |
|---|---|---|
| **自动检查更新**（勾选） | 关掉后启动 / 定时 / 窗口聚焦 / 休眠恢复都不再自动检查，也不会提示新版本；手动「检查更新…」不受影响 | `updates.automaticChecks` |
| **回滚到旧版本 ▸** | 列出比当前版本更早的归档版本（读 `<origin>/versions.json`），确认后走既有的下载 → sha512 校验 → 替换自身 → 重启流程 | `updates.pinnedFeedUrl` |
| **解除版本锁定** | 回滚后出现；把更新源换回产物自带的那条，并关掉降级许可 | 同上 |

细节与边界：

- **只列更早的版本**，而且回滚完成后会自动关掉「自动检查更新」、把更新源**锁定**到该版本的归档 release，
  所以不会立刻被提示升回新版；想恢复跟随时点「解除版本锁定」。
- **数据格式守卫**：目录里每个版本都带 `sessionFormatVersion` / `storageSchemaVersion`（CI 在构建期从上游源码读出，
  写进归档 release 正文）。目标版本低于当前版本时菜单里会标「（可能读不了当前数据）」，确认框逐条列出风险，
  并且**默认按钮是取消**；无法判定（目录里没有当前版本、或字段缺失）也按不安全处理。
  会话查询缓存（`SESSION_QUERY_SQLITE_SCHEMA_VERSION`）是可重建的派生数据，不参与守卫。
- **只有以 AppImage 方式运行才有这个入口**：替换自身依赖 `$APPIMAGE`，deb/rpm 安装的那份不显示「回滚到旧版本」。
- 偏好写在 Electron 的 userData 下（本机为 `~/.config/@deepseek-ai/dsh-desktop/desktop/settings.json`，权限 0600）；
  文件损坏或读不动时**不会被覆盖**，只回落到默认值（自动检查=开、无锁定）。
- 锁定期间把「自动检查更新」再勾上也没问题：它只会查那一条被锁定的 feed，看不到新版。
- 回滚用的目录由 CI 在每次滚动发布时重新生成，字段来源是各归档 release 正文里的 HTML 注释，
  生成脚本是 [scripts/versions-index.mjs](../scripts/versions-index.mjs)。

### 版本号：同一上游版本重发时必须递增

`nightly-linux.yml` 的 `version` 会与已安装应用的 `app.getVersion()` 做 `semver.gt` 比较，所以
**补丁修复后重发同一个上游版本时，版本号必须变大**，否则老用户只会看到「已是最新」。约定沿用上游
`desktop-build-version.mjs` 的形式：

| 第几次构建该上游版本 | 版本号 | 例 |
|---|---|---|
| 第 1 次（新上游 tag） | 与上游一致 | `0.2.1-alpha.2` |
| 第 2 次起（补丁修复后重发） | `<上游版本>.<日期>.<序号>` | `0.2.1-alpha.2.20261009.2` |

序号记在 release 正文的 `build-number` 里，每次发布 +1；格式写错会在打包前被上游自己的校验拦下。
本地复现时用 `DSH_DESKTOP_BUILD_VERSION=… ./scripts/build.sh --appimage`。

滚动 tag 而不是 `releases/latest/download` 是有原因的：上游版本号都带
`-rc.N` / `-alpha.N`，如果按 GitHub 的 prerelease 语义发布，`releases/latest` 就不会指向它，
feed 会 404。`releases/download/<tag>/` 对任何 release 都成立，所以用固定 tag。

## 应用内的表现

- **菜单 Application → Check for Updates**：手动检查。失败/无更新/有更新都有反馈，并显示当前版本。
- 自动检查不会弹窗、不会下载；只有用户在侧栏更新入口或对话框里确认后才下载。
- 下载完成后出现「重启并安装」确认；确认后应用停掉 Harness Host、替换 AppImage 并重启。
- 替换的是**正在运行的那个 AppImage 文件本身**，所以文件必须可写（放在
  `/opt` 或 root 拥有的目录里会失败）。deb/rpm 安装的那份不走这条路径。

## 安全

- Linux 产物是 **unsigned** 的，electron-updater 对 AppImage 只做 sha512 校验，没有签名校验。
  feed 的信任边界等于「谁能写这个 feed」，务必用你自己控制的 HTTPS 源。
- `DSH_DESKTOP_LINUX_UPDATE_ORIGIN` 是运行期变量：能设置它的人本来就能替换 AppImage，
  所以它不额外扩大权限，但它决定了应用去信任哪个 feed。
- 明文 HTTP 只对回环地址开放，公网地址会在**打包期**就被 `resolveDesktopLinuxUpdateConfig` 拒掉。

## 本地验证更新链路

```bash
# 1. 构建（带上 .env.linux 里的回环 feed 地址）
DSH_DESKTOP_LINUX_UPDATE_ORIGIN=http://127.0.0.1:8899 ./scripts/build.sh --appimage

# 2. 起 feed
./scripts/serve-update-feed.sh

# 3. 另开一个终端跑 AppImage，并让运行期覆盖指到同一个 feed
DSH_DESKTOP_LINUX_UPDATE_ORIGIN=http://127.0.0.1:8899 \
  ./upstream/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/*.AppImage
```

想要看到「有新版本」而不是「已是最新」，把 feed 目录里 `nightly-linux.yml` 的 `version`
改成比当前应用更高的版本号即可（比如把 `0.2.1-alpha.2` 改成 `0.2.1-alpha.3`）；
载荷复用同一个 AppImage 就能跑通下载与安装，不必真的编两遍。
