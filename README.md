# DeepSeek Harness Desktop for Linux

把官方桌面端（[`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness) 的
`apps/desktop`）搬到 Linux，并把它在 Linux 上缺的那几块补齐。跑的就是上游那份 Electron 应用，
不是套壳浏览器。

![Ubuntu 26.04 / GNOME / Wayland 实拍](docs/screenshot.png)

<sub>实拍：原生标题栏和菜单栏都没了，只剩 40px 标题条 + 系统风格窗口按钮，应用/编辑变成标题条上的弹出菜单。</sub>

## 和“能跑起来”的区别

| | |
|---|---|
| **跨平台外观** | 上游只在 Windows 画自定义标题栏，Linux 会落回 GTK 标题栏**加**菜单栏（实测非客户区 110px）。这里让 Linux 走与 Windows 同一条路径：40px 标题条、Electron overlay 画的系统风格窗口按钮、原生菜单栏收进标题条 |
| **应用内更新** | 上游更新通道只认 mac/win，而且 unsigned 构建直接跳过更新配置。这里接通了 AppImage 通道：`检查更新 → 下载 → 校验 sha512 → 替换自身 → 重启` |
| **一条命令装好** | 下载最新发布 → 校验 sha512 → 装进 `~/.local` → 建桌面快捷方式。装在用户目录而不是 `/opt`，是为了让自更新能替换自身文件 |
| **自动跟进上游** | CI 每天扫上游 tag，补丁能打上就自动构建发布；应用内更新读同一个 release。幂等键是「上游 ref + 补丁集指纹」，所以补丁修好后推到 master 会立刻重发，只改文档则不会触发重编；重发时版本号递增（`<上游版本>.<日期>.<序号>`），已安装的用户也能收到这次修复。补丁冲突时流水线失败并发邮件，不会发出半成品 |

## 安装

```bash
git clone https://github.com/JamesYasR/dsh-desktop-linux
cd dsh-desktop-linux
./scripts/install-from-release.sh
```

也可以直接从 [Releases](../../releases) 取 AppImage，`chmod +x` 后运行；同一个 release 里还有 `.deb`
（Debian / Ubuntu：`sudo apt install ./deepseek-harness-*.deb`）。

deb 装出来的那份**不能应用内自更新**（自更新要替换正在运行的 AppImage 文件），升级请重新下载安装。

## 从源码构建

需要 Node 22.19+ 或 24、pnpm 11。

```bash
./scripts/fetch-upstream.sh      # 拉上游源码到 ./upstream
./scripts/apply-patches.sh       # 打补丁
./scripts/build.sh --appimage    # 也支持 --deb / --rpm / --all
```

改了补丁（或准备推给 CI）之前，先跑一遍预检——它把 CI 会因为补丁/依赖/类型失败的事在本机做掉：

```bash
./scripts/preflight.sh           # PKGBUILD 自洽 + 两条路径打补丁并逐字节比对 + host 面类型检查
./scripts/preflight.sh --full    # 再加 CI 同款 build:lib（含 tsdown，慢，十几分钟）
./scripts/preflight.sh --clean    # 跑完删掉 upstream/（含 node_modules，约 2.4G）
```

## 上游发新版了

通常什么都不用做：CI 会跟进，应用里点「检查更新」即可。想在本机直接编：

```bash
./scripts/upgrade.sh --check     # 先验证补丁还打不打得上；失败会完整回滚并指出该改哪个文件
./scripts/upgrade.sh             # 验证通过后构建 + 重装
```

细节见 [docs/upgrading.md](docs/upgrading.md) 与 [docs/updates.md](docs/updates.md)。

补丁需要重做时：改完先跑 `./scripts/preflight.sh`，通过后推 master——补丁集指纹变了，CI 会立刻重发，
既不用等定时任务，也不用去改上游 ref。

## 补丁

18 个。`0001–0015`（不含已作废的 `0014`）是社区移植基础，来自
[ffyfox/dsh-desktop-linux](https://github.com/ffyfox/dsh-desktop-linux)，本仓库保留了其提交历史；
`0016–0019` 是本项目加的：应用内更新通道、运行期换更新源、跨平台标题栏，以及 CLI 在未打包布局下
定位运行时。逐个说明在 [patches/README.md](patches/README.md)。

## 已知限制

- 托盘走 StatusNotifierItem，GNOME 需要 `gnome-shell-extension-appindicator`（Ubuntu 默认已装）。
- 产物 unsigned，更新只校验 sha512、没有签名校验，所以 feed 必须是发布者自己控制的 HTTPS 源。
- 只出 x86_64。
- deb / rpm / Arch 包能构建，但应用内自更新只对 AppImage 生效（安装时替换的是正在运行的 AppImage 文件本身）。

## 许可

MIT。社区项目，与 DeepSeek 官方无隶属关系；DeepSeek Harness 及其依赖仍受各自上游许可与商标政策约束。
