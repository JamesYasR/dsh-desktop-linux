# 失败点与发现记录

每次失败/成功都往这里加一条。格式：日期、环境、命令、结果、结论。

---

## 2026-09-25 · 阶段 1 · dev 模式（go/no-go 关卡）—— **通过：窗口能弹出来**

**环境**：Arch Linux，KDE Plasma Wayland（`WAYLAND_DISPLAY=wayland-0`，XWayland `DISPLAY=:1`），
Node v26.9.0，系统 pnpm 9.15.4，`/home` 起始剩 30G。
上游 checkout：`deepseek-ai/deepseek-harness@477b4f4`（rel/dsh-0.1.7-rc.2，`--depth 1`，183M）。

### 结果

```bash
cd upstream
DSH_HOME=/tmp/dsh-desktop-test pnpm run dev:desktop
```

Electron 壳起来了，**主窗口正常弹出并渲染出官方欢迎页**：

- 窗口标题 `DeepSeek Harness`，菜单栏 `Application | Edit`
- 页面内容：DeepSeek HARNESS logo / "Welcome to DeepSeek Harness" / "Build potential. Explore intelligence." /
  `Sign in` / `Add API Key`
- 渲染器目标（`http://127.0.0.1:9222/json/list`）：
  - `title="DSH Local Build"  url=dsh-app://app/` ← **`dsh-app://` 协议工作正常**
  - `title="DeepSeek Harness"  url=file://…/apps/desktop/renderer/welcome.html`
- 内置 Host 监听 `127.0.0.1:19387`（与 BRIEF 记录的桌面端默认端口一致），日志打出
  `dsh web: http://127.0.0.1:19387/?token=…`
- 渲染进程走 **Wayland 原生 ozone**（GPU 进程 `--ozone-platform=wayland`），
  网络进程带 `--standard-schemes=dsh-app --secure-schemes=dsh-app`
- UI 自己认出平台：DOM 为 `<html lang="en" data-platform="linux" data-ds-theme-source="system">`

隔离性同时验证通过：

- primary-runtime 按 **linux-x64** 准备：`runtime.json` 里 `platform: linux, arch: x64`，474M，
  含 Node 归档、Python 解释器与 13 个 wheels（numpy/pandas/python-docx/python-pptx/openpyxl/Pillow/lxml…）
- `DSH_HOME=/tmp/dsh-desktop-test` 下生成了 `profiles/desktop`
- **`~/.dsh/profiles/` 里没有出现 `desktop`**，正在用的 `web` profile 未被污染；
  3080 上的 GUI 全程正常

### 三个真实阻塞点（按撞到的顺序）

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| 1 | `git clone` → `TLS connect error: unexpected eof` | 代理 `127.0.0.1:7897` 瞬时抖动（同一时刻 `api.github.com` 通、`github.com` 断）；重试即通 | 重试 |
| 2 | `pnpm install --frozen-lockfile` → `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH` | 系统 pnpm 9.15.4 读不懂 `pnpm-workspace.yaml` 里的 `overrides`/`allowBuilds`/`minimumReleaseAgeExclude`（pnpm 10+ 字段）。根 `package.json` 要求 `packageManager: pnpm@11.7.0`，且本机没有 corepack | 装隔离的 pnpm 11.7.0（`npm i --prefix ~/.local/share/dsh-pnpm-11 pnpm@11.7.0`），不动全局 9.15.4 |
| 3 | `tsx scripts/dev.ts` → `ERR_MODULE_NOT_FOUND: @deepseek-ai/dsh-app-boot/lib/index.js` | 干净树上 `lib/` 不存在。`dev.ts` 的 import 是**静态提升**的，在 `main()` 里那次 `pnpm run build` 之前就解析模块 → 鸡生蛋 | 先手动跑一次 `pnpm run build` |

补丁（见下）是第四个必要条件。

### BRIEF 里需要更正的三处

**1. 「dev 模式不走 `package-target.ts`，所以 Linux 上不需要任何补丁」—— 前半对，后半错。**

`dev.ts` 确实不碰 `package-target.ts`，但调用链里另有一份 target 白名单：

```
dev:desktop → apps/desktop/scripts/dev.ts
  └─ prepareDevelopmentProject({ …, target: resolveDesktopBuildTarget() })
       └─ scripts/desktop-build-paths.mjs
            SUPPORTED_TARGETS = {mac-arm64, mac-x64, win-x64}   ← Linux 撞这里
```

不浪费一次全量构建即可复现：

```bash
cd upstream/apps/desktop
node --input-type=module -e "import('./scripts/desktop-build-paths.mjs').then(m=>m.resolveDesktopBuildTarget())"
# → desktop build paths: unsupported target linux-x64
```

同一份白名单还在 `scripts/desktop-auto-update-environment.mjs`（`UPDATE_TARGETS`）
与 `scripts/desktop-auto-update-environment.d.mts`（`DesktopAutoUpdateTarget` 类型）里各有一份。

**2. 「`node-pty` 没有 linux-x64 prebuild」—— 对这个版本不成立。**

`node-pty@1.2.0-beta.15` 装完就有 `prebuilds/linux-x64/pty.node`（上游还对这个版本有
`patches/node-pty@1.2.0-beta.15.patch`）。BRIEF 引用的 Discussion #605 描述的行为在
当前版本已不复现。

**3. 「`sharp` 需要 `--os=linux --cpu=x64` 处理」—— 不成立。**

`pnpm install` 直接把 `@img/sharp-linux-x64@0.35.3` 装好了，原生模块就位。

> 阶段 3（原生模块）的风险等级应当大幅下调：两个已知阻塞点在当前版本都不存在。

### 一个被我自己误诊、随后更正的坑（记下来免得重复踩）

现象：装完 `pnpm install` 后 `node_modules/.pnpm/electron@44.0.0/…/electron/` 里
既没有 `path.txt` 也没有 `dist/`。第一反应是「`electron` 不在 `allowBuilds` 里，
postinstall 被 pnpm 跳过了」。

**这个诊断是错的。** 实际原因：`electron@44.0.0` 的 `package.json` **根本没有 `scripts` 字段**，
没有 `postinstall`。它把下载脚本改成了显式的 bin：

```json
"bin": { "electron": "cli.js", "install-electron": "install.js" }
```

而且 `electron/index.js` 在 `require` 时**会自动补齐**——缺 `path.txt`/`dist` 就自己
spawn `install.js` 下载。实测：

```
$ node -e "require('electron')"
Downloading Electron binary...
返回路径: …/electron/dist/electron
```

所以：

- 手动跑 `install.js` 是**不必要的**，第一次 `require('electron')` 会自己下载；
- 往 `pnpm-workspace.yaml` 的 `allowBuilds` 加 `electron: true` 是**无效改动**（没有脚本可允许），
  已在隔离工程里实测确认（加了也一样不产出 `path.txt`）。这个改动已回退，没有进补丁集。

对打包流程的实际含义：Electron 二进制约 117MB，首次 `require` 时才下载，
**离线/可复现构建应当在构建脚本里显式预热**（`pnpm --filter @deepseek-ai/dsh-desktop exec install-electron`
或直接 `node …/electron/install.js`），并配 `ELECTRON_CACHE` 缓存。

### 上游测试显式断言 Linux 不受支持

加白名单会让这些测试失败，改白名单时必须同步改测试：

- `tests/desktop-build-paths.spec.ts:66` `resolveDesktopBuildTarget({}, 'linux', 'x64')` 期望抛错
- `tests/desktop-auto-update-environment.spec.ts:110` 同上
- `tests/package-target.spec.ts:29` 同上
- `tests/README.md:81` 提到「开发启动器在此 Windows 工作区遇到指向缺失目标的可选 Linux ARM64 依赖 junction」

### 一条重要的好消息：Electron 壳本身已经支持 Linux

`apps/desktop/` 里大量代码已按 `linux` 分支写好，**唯一挡住的是发布/打包的 target 白名单**：

- `src/main.ts:637` 菜单按 `darwin / win32 / linux` 三分支
- `src/runtime-tree.ts` 的 `platform` 用 `NodeJS.Platform`，`'linux'` 本来合法
- `scripts/prepare.ts:147` 已处理 `target.startsWith('linux-')` → `platform: 'linux'`
- `scripts/primary-runtime/lock.json` 的 targets **已含 `linux-x64` 与 `linux-arm64`**
  （Node 归档、Python 解释器、wheels 全都有）
- README 里 Linux 的 zenity/kdialog 目录选择、快捷键分发、崩溃日志路径都已描述

也就是说：**这不是"移植"，而是"把已经写好的 Linux 支持从白名单后面放出来"。**

### 复现步骤（最小可跑通路径）

```bash
# 1. 用仓库要求的 pnpm
npm i --prefix ~/.local/share/dsh-pnpm-11 pnpm@11.7.0
export PATH="$HOME/.local/share/dsh-pnpm-11/node_modules/.bin:$PATH"

# 2. 拉上游 + 打补丁
cd ~/projects/dsh-desktop-linux
./scripts/fetch-upstream.sh
./scripts/apply-patches.sh

# 3. 安装（必须在 upstream 里）
cd upstream && pnpm install --frozen-lockfile

# 4. 关键：先全量构建一次（dev.ts 的静态 import 需要 lib/ 已存在）
pnpm run build

# 5. 起窗口
DSH_HOME=/tmp/dsh-desktop-test pnpm run dev:desktop
```

`dev.ts` 默认 `DSH_DESKTOP_OPEN_DEVTOOLS=1` 会自动弹 DevTools；想看干净的窗口设
`DSH_DESKTOP_OPEN_DEVTOOLS=0`，并用 `pnpm run start:desktop`（= `dev.ts --skip-build`）跳过重复构建。

---

## 补丁清单

| 补丁 | 内容 | 状态 |
|---|---|---|
| `0001-desktop-target-allow-linux-x64.patch` | `desktop-build-paths.mjs` 的 `SUPPORTED_TARGETS` + JSDoc 类型 + `desktopTargetPlatform` 的 linux 分支；`desktop-auto-update-environment.mjs/.d.mts` 的 `UPDATE_TARGETS` 与类型 | 已验证可干净重放，且是窗口能起来的必要条件 |

尚未打、阶段 2 需要：

- `package-target.ts` 的 `DesktopPackageTargetName` / `TARGETS` 表 / `resolveDesktopPackageTarget`
- `desktop-upload-plan.ts` 的 `TARGETS`（`satisfies Record<DesktopPackageTargetName, …>`，加目标必须同步加条目）
- `electron-builder-config.mjs` 里 `unsigned && resolvedPlatform !== 'win32'` 那条限制
- `apps/desktop/package.json` 加 `package:linux:x64` 脚本
- 上节列出的四个测试断言

---

## 背景速查（来自 BRIEF.md）

| 项 | 值 |
|---|---|
| 包名 | `@deepseek-ai/dsh-desktop`（`private: true`，不在 npm 上） |
| 版本 | 0.1.7-rc.2 |
| Linux 支持 | 明确不支持（README） |
| 打包目标类型 | `'mac-arm64' \| 'mac-x64' \| 'win-x64'` |
| Linux target 配置 | **已存在**：`linux: { category: 'Development', target: ['AppImage'] }` |
| URL scheme | `dsh://`（打包用）；dev 模式实测走 `dsh-app://` |
| 默认端口 | 19387（dev 模式实测一致） |
| 未签名构建 | `unsigned && resolvedPlatform !== 'win32'` 直接抛错，AppImage 不需要签名，要放宽 |
