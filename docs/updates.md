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

通道名固定为 `nightly`（`update-coordinator.ts` 里写死），所以元数据文件名是
`nightly-linux.yml`，不是 electron-builder 默认的 `latest-linux.yml`。发布时两个名字都要对。

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
