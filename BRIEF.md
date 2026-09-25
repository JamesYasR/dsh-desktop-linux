# dsh-desktop-linux —— 开工交接

> 写于 2026-09-25，来自上一个工作区（那次做的是 dsh 插件与 profile 管理）。
> 这份文件是给新工作区的自足交接：目标、已查证的事实、已定的决策、开发流程、以及踩过的坑。

---

## 一、目标

**给官方 DeepSeek Harness 桌面端补上 Linux 目标。**

官方桌面端（`deepseek-ai/deepseek-harness` 的 `apps/desktop`）只发布 macOS 与 Windows，Linux 被明确排除。本项目的产物是 Linux 上可用的官方桌面端构建：AppImage / deb / rpm / PKGBUILD。

**关键区分**：这不是再写一个套壳。生态里已有十几个"启动 `dsh web` + 套个窗口"的社区桌面端。本项目要做的是**把官方 Electron 桌面端的打包流水线移植到 Linux**——官方桌面端有自己的 `dsh-app://` 协议、分帧字节管道、内置 Node 与 pnpm、独占 `desktop` profile，它没法被"套壳"，只能从源码构建。

---

## 二、已定的决策

| 项 | 决定 |
|---|---|
| GitHub 仓库 | `ffyfox/dsh-desktop-linux` |
| AUR 包名 | `deepseek-harness-desktop`（钉 tag 构建）或 `-git`（跟 master） |
| npm | 暂不发（本项目不是 dsh 插件，产物是 AppImage/deb/rpm） |
| 构建架构 | 独立打包仓库（patch + 脚本 + PKGBUILD），**不 fork monorepo** |

AUR 名字可用性已查（2026-09-25）：`deepseek-harness-desktop` 与 `deepseek-harness-desktop-git` **均空着**；`dsh-desktop-git` 被 xuewuerduo 打包的 dataelement 社区版占着，不能用。

---

## 三、已查证的事实（带出处，不必重查）

### 官方桌面端现状

| 项 | 值 | 出处 |
|---|---|---|
| 包名 | `@deepseek-ai/dsh-desktop`（`private: true`，不在 npm 上） | `apps/desktop/package.json` |
| 版本 | 0.1.7-rc.2 | 同上 |
| Linux 支持 | **明确不支持** | `apps/desktop/README.md`："Linux is not a supported Desktop release target." |
| 目标类型 | `'mac-arm64' \| 'mac-x64' \| 'win-x64'` | `apps/desktop/scripts/package-target.ts:31` |
| `platform` 联合类型 | `'darwin' \| 'win32'` | 同上，`DesktopPackageTarget` |
| `builderPlatform` | `'--mac' \| '--win'` | 同上 |
| Linux 主机 | `hostTargetName()` 算出 `linux-x64` → `isTargetName` 失败 → 抛 `unsupported build host linux-x64` | 同上 |
| Linux target 配置 | **已存在**：`linux: { category: 'Development', target: ['AppImage'] }` | `apps/desktop/scripts/electron-builder-config.mjs` |
| `productName` | `DeepSeek Harness` | 同上 |
| `artifactName` | `deepseek-harness-${version}-${os}-${arch}.${ext}` | 同上 |
| URL scheme | **`dsh://`**（`protocols: [{ name: 'DeepSeek Harness', schemes: ['dsh'] }]`） | 同上 |
| 默认端口 | **19387**（与 web 的 3080 分开） | `apps/desktop/README.md` |
| `package.json` scripts | 只有 `package:mac:arm64` / `mac:x64` / `win:x64`，**无 linux** | `apps/desktop/package.json` |
| 未签名构建 | `unsigned && resolvedPlatform !== 'win32'` 直接抛错 —— AppImage 不需要签名，这条要放宽 | `scripts/electron-builder-config.mjs` |
| 上游 Issues / PRs | **两者都关闭**，补丁提不上去 | 仓库设置 |

### 官方桌面端已流出（但未官宣）

- 下载版本 V0.1.7-rc.1，Mac 版签名主体 `Hangzhou DeepSeek Artificial Intelligence Co., Ltd`，Bundle ID `com.deepseek.dsh`，已过 Apple 公证
- 更新源指向 `download.deepseek.com`，走 nightly 通道
- 机器之心原话：「这个客户端目前还不支持 Linux，于是一个只有 Linux 用户受伤的世界形成了」

### 已知阻塞点

1. **`node-pty` 没有 linux-x64 prebuild**（Discussion #605）。它的安装脚本 `node scripts/prebuild.js || node-gyp rebuild` 在 Linux 上会静默 exit 0 却不产出 `pty.node`。这个坑不只卡官方桌面，也卡所有从 npm 装的 Linux 用户。AUR 的 `deepseek-harness-bin` 曾为此写手动 `node-gyp rebuild` 兜底。
2. **`sharp`** 在 Linux 上需要 `--os=linux --cpu=x64` 处理（AUR 的 `deepseek-harness-git` 评论区有完整报错）。
3. `@deepseek-ai/dsh-desktop` 是 `private: true`，**不在 npm 上** → PKGBUILD 必须从 monorepo git 源码构建（pnpm workspace + tsc + tsdown + electron-builder + `prepare:dsh`），比社区那种 `npm ci` 重得多。

### 上游沟通入口

- [Discussion #6606](https://github.com/deepseek-ai/deepseek-harness/discussions/6606)（2026-09-14）：有人把"AppImage 配置存在但 target 表够不到"这个矛盾完整摆出来，还主动说"愿意在 Linux x64 上试打 AppImage 并报告具体在哪一步失败"。**至今 0 回复。**

---

## 四、开发流程

### 阶段 0：建仓 + 隔离

仓库结构（独立打包仓库，不 fork monorepo）：

```
dsh-desktop-linux/
├── README.md
├── docs/
│   └── findings.md          ← 每次失败点记录，这是最值钱的产出
├── patches/
│   ├── 0001-package-target-add-linux.patch
│   └── 0002-allow-unsigned-linux.patch
├── scripts/
│   ├── fetch-upstream.sh    # clone + checkout 指定 tag
│   ├── apply-patches.sh
│   ├── build.sh
│   └── verify.sh
├── PKGBUILD
└── .github/workflows/build.yml
```

理由：上游是 235k star 的巨型仓库，fork 后 rebase 成本高；PKGBUILD 本来就是"clone tag + 打补丁 + 构建"的形状；补丁文件随时能拿去贴 Discussion。

### 阶段 1：先跑 dev 模式 ← 最便宜，先做这个

**关键洞察**：`pnpm run dev:desktop` **不走 `package-target.ts`**。它用系统自己的 Node 跑 CLI + 私有 Desktop Host 包，所以 Linux 上理论上不需要任何补丁就能跑。

```bash
git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness.git upstream
cd upstream
pnpm install
DSH_HOME=/tmp/dsh-desktop-test pnpm run dev:desktop
```

- **弹窗了** → 可行性基本确认，剩下全是打包工程
- **炸了** → 先解决它，这是所有后续步骤的地基

**这是第一个 go/no-go 关卡。** 成本：一次 clone + install，估计 20–40 分钟。

### 阶段 2：定位打包失败点

```bash
DSH_HOME=/tmp/dsh-desktop-test pnpm --dir apps/desktop run package:dir
```

预期报 `desktop package: unsupported build host linux-x64`。然后开始打补丁，**每处改动一个 patch 文件**（`git format-patch` 生成，便于 rebase 上游）。已知要动的：

1. `package-target.ts` 的三个类型联合 + `TARGETS` 表 + `hostTargetName()`
2. `unsigned && resolvedPlatform !== 'win32'` 那条限制
3. `apps/desktop/package.json` 加 `package:linux:x64` 脚本

### 阶段 3：原生模块

`node-pty`（需要 `pty.node`）、`sharp`。

### 阶段 4：产物，按这个顺序

**AppImage → deb → rpm → PKGBUILD**

AppImage 优先，因为它是 `electron-builder-config.mjs` 里**唯一已声明的 linux target**。

### 阶段 5：验证矩阵

- 窗口起得来
- `dsh-app://` 协议加载 UI 正常
- 与 CLI **共享** `~/.dsh`（会话 / 设置 / 凭据）
- **独占** `profiles/desktop`，不污染 `web` profile
- 不跟 3080 上的服务打架（官方桌面端默认 19387）

### 阶段 6：回到上游

去 Discussion #6606 汇报发现。注意上游 Issues/PRs 关闭，只能 fork 或走 Discussion。

---

## 五、约束与纪律

1. **`DSH_HOME` 指向临时目录。** 本机 3080 上跑着 GUI，`~/.dsh` 有 1.7G。官方桌面端要用 `profiles/desktop`，别让它碰正在用的 `web` profile。
2. **磁盘**：`/home` 只剩 **28G**（2026-09-25 清理缓存后）。这个构建要吃 monorepo clone + pnpm store + Electron 二进制（~200MB）+ electron-builder 产物。开工前确认空间。
3. **上游 Issues 与 PRs 都关闭**，别指望提 PR。
4. 这台机器：Arch Linux，Node v26.9.0，npm 12.0.2，pnpm 9.15.4，`yay` 与 `paru` 都在。

---

## 六、生态里已有的 Linux 项目（避免重复造轮子）

**没有任何一个打包官方桌面端。** 全部是"启动 `dsh web` + 套壳"，架构完全不同。

| 项目 | Linux 产物 | 备注 |
|---|---|---|
| `dsh-tauri/deepseek-harness-desktop`（原 `hairyf/`） | AppImage + deb | Tauri，~5MB。有 `build-linux.yml` 与 `fix-appimage-host-libs.sh`。已知 Arch/Fedora 崩溃、Wayland 黑屏 |
| DSH-Desktop-EAC | deb/AppImage v5.3.6，rpm/pacman 停在 v4.4.0 | ~1.6k star，Tauri 2 |
| `agent-earth/deepseek-harness-desktop` | AppImage + deb | README 有验证表 |
| `huangj17/deepseek-harness-desktop` | AppImage + deb | Electron |
| `WSL043/DSH-Portable` | AppImage x64 + **ARM64** | 唯一明确有 ARM64 的 |
| `RongleCat/deepseek-app` | AppImage / deb / **rpm** | 36 star，2026-08-16 后停更 |
| `web-casa/DeepSeek-Harness-Desktop` | **Snap** | `dsh-desktop-community` |
| `zsyu9779/dsh-desktop` | Linux amd64 **tar.gz** | Wails/Go，要求系统已有 Node + WebKitGTK |
| `lin-1259/dsh-desktop-linux-updater` | — | **最接近的邻居**：给 Linux 自建版做一键更新。但它自建的是 `dataelement/dsh-desktop`（社区版），不是官方 |
| `anywhere-labs/dsh-desktop`（~28k star） | ❌ 仅 Win/macOS | 最大社区项目，明确不支持 Linux |
| `dataelement/dsh-desktop`（8.1k star） | ❌ 平台表写 "Linux — Not currently supported" | |

包管理器：AUR 上 CLI 包 `deepseek-harness-bin`（10 votes，Aromatic 维护）维护得不错；桌面包只有 `dsh-desktop-git`（0 votes，打包 dataelement 版）。**Flathub 上没搜到**（弱证据，搜索页是前端渲染）。

---

## 七、与旧插件的关系

上一个工作区给本机的一个 DSH 插件做了改名（把 `dsh-desktop` / `dsh-linux-desktop` 这两个名字让出来给本项目）：

- 仓库 `~/projects/dsh-linux-desktop`
- 改动在分支 **`rename/dsh-lxi`**（commit `210af27`），**刻意未推送、未发布、未改动本机运行环境**
- 如果本项目失败，那边还原只需 `git checkout main && git branch -D rename/dsh-lxi`
- 本项目成功后再回去推 `rename/dsh-lxi`

所以：**`dsh-desktop` 这个名字目前在本机仍被旧插件占着**（`~/.local/bin/dsh-desktop`），但代码侧已经让出来了。

---

## 八、起手命令

```bash
cd ~/projects/dsh-desktop-linux
df -h /home                     # 确认 ≥10G 可用

git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness.git upstream
cd upstream
pnpm install
DSH_HOME=/tmp/dsh-desktop-test pnpm run dev:desktop
```

第一个问题只有一个：**窗口能不能弹出来。**
