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

## 2026-09-25 · 阶段 2 · 打包链路定位 —— **推进到 `prepare:dsh`，卡在 sharp 解码段错误**

```bash
cd upstream
DSH_HOME=/tmp/dsh-desktop-test pnpm --dir apps/desktop run package:linux:x64:dir
```

### 打补丁前：BRIEF 预测的报错完全命中

```
$ tsx scripts/package-target.ts --dir
Error: desktop package: unsupported build host linux-x64
    at hostTargetName (package-target.ts)
    at parseDesktopPackageInvocation (package-target.ts)
```

### 打完 7 个补丁后：链路推进了 5 个阶段

```
configuration ✓ → toolchain ✓ → build:official ✓ → release:pack(dsh+vendor+landlock) ✓
→ prepare:runtime ✓ → prepare:packages ✓ → prepare:dsh ✗（32s 后 exit 1）
```

`prepare:runtime` 成功这一步很关键：它按 `desktopTargetPlatform('linux-x64')` 下载并解压了
**linux-x64 的 Electron 44 发行包**，并跑通了 `electron -p process.versions.node` 取版本号——
说明 target 化的 Electron 分发路径（补丁 0004）是对的。

`desktop package: linux-x64 publishes 0.1.7-rc.2` 也已正常打出，说明
`loadDesktopPackageEnvironment` / `validateDesktopPackageEnvironment`（补丁 0005）
和 policy 设置都能在 Linux 下通过。

### 失败点：`sharp` 的 PNG 解码在 Electron 44 / Linux 下段错误

`prepare:dsh` 的最后一步是运行时冒烟（`tests/fixtures/runtime-payload-smoke.mjs`），
它在打包用的 Electron Node 运行时下依次检查 pnpm / koffi / sharp / HTML / pty / ripgrep。
插桩定位到**崩在 `checkSharp()`**：

```
>>> 3 checkKoffi
>>> 3 done
>>> 4 checkSharp
(node:216611) [SharpElectronLinux] Warning: Binaries provided by Electron for use on Linux
  may be incompatible with sharp - see https://sharp.pixelplumbing.com/install#electron-and-linux
EXIT=139          ← Segmentation fault (core dumped)
```

**最小复现**（三行，可直接跑）：

```bash
T=apps/desktop/.desktop-build/targets/linux-x64
cat > /tmp/sharp-decode.mjs <<'EOF'
import { createRequire } from 'node:module'
import { join } from 'node:path'
const req = createRequire(join(process.argv[2], 'package.json'))
const sharp = req('sharp')
const png = await sharp(Buffer.from([17,103,231]), { raw: { width: 1, height: 1, channels: 3 } }).png().toBuffer()
console.error('encoded', png.length, '→ decode')
const d = await sharp(png).raw().toBuffer({ resolveWithObject: true })
console.error('decoded', d.info.width, d.info.height, d.info.channels)
EOF

# 打包用 Electron：编码成功，解码段错误
ELECTRON_RUN_AS_NODE=1 "$T/electron/electron" --expose-internals /tmp/sharp-decode.mjs "$T/dsh"
#   encoded 90 → decode
#   Segmentation fault (core dumped)        EXIT=139

# 同一个脚本、同一份 node_modules，换成系统 Node：完全正常
node /tmp/sharp-decode.mjs "$T/dsh"
#   encoded 90 → decode
#   decoded 1 1 3                           EXIT=0
```

**隔离结论**：

| 变量 | 结果 |
|---|---|
| sharp 编码（raw → png）在 Electron 下 | ✅ 通过（90 字节） |
| sharp **解码**（png → raw）在 Electron 下 | ❌ SIGSEGV |
| 同一解码在系统 Node 下 | ✅ 通过 |
| 有无 koffi 的 `load(null)`/`unload()` | 与崩溃无关（两个变体都崩） |

**根因**（sharp 官方 install 文档「Electron and Linux」一节原文）：
> Binaries provided by Electron for use on Linux dynamically link against a globally-installed
> `glib` and leak its symbols into the process space, which may cause the following error to occur:
> … `GLib-GObject: g_object_ref: assertion 'G_IS_OBJECT (object)' failed`
> Please subscribe to electron#46323 for updates.

本机实测与文档一致：

```
$ ldd .desktop-build/targets/linux-x64/electron/electron | grep glib
    libglib-2.0.so.0  => /usr/lib/libglib-2.0.so.0     ← Electron 动态链接系统 glib
    libgobject-2.0.so.0 => /usr/lib/libgobject-2.0.so.0
    libgio-2.0.so.0   => /usr/lib/libgio-2.0.so.0
$ pacman -Q glib2
    glib2 2.88.3-1
```

Electron 进程空间里已经加载了系统 glib，sharp 自带的 libvips
（`@img/sharp-libvips-linux-x64/lib/libvips-cpp.so.8.18.6`，**不自带 glib**）随后绑定到它，
在走 GLib 的加载器路径（PNG 解码）时崩溃。

> 注意这是**版本相关**的：sharp 文档说的是 "may cause"。在 glib 版本与 libvips
> 期望更接近的发行版上可能不复现。本机 Arch + glib 2.88.3 稳定复现。

### 这个阻塞点不是白名单能修的

前 7 个补丁都是「把已有支持放出来」形状的改动，这一个不是。候选方向（需要决策，尚未验证）：

1. **换 WASM sharp**（`@img/sharp-wasm32`）——绕开原生 libvips 与 glib，代价是性能与功能覆盖。
2. **把图像处理挪出 Electron 进程**——primary-runtime 里本来就带一个**真正的 Node**
   （`primary-runtime/dependencies/node`），sharp 在真 Node 下正常。但要改上游的运行时分工。
3. **接受冒烟失败**，在补丁里让 Linux 跳过 `checkSharp`——这会把一个真实的崩溃藏起来，
   而 `sharp` 在桌面端是图像附件/图片卸载路径上的依赖，**不建议**。
4. 等 upstream 修 electron#46323。

**在解决之前，`package:linux:x64:dir` 无法走完**，因此还没有 `linux-unpacked` 产物。

### 另一个需要产品决策的点：Linux 的 mandatory-update policy origin

`resolveDesktopPolicyEnvironment` 在 `--unsigned` 提前返回**之前**执行，所以即使是
unsigned 的 Linux 构建也**必须**提供 `DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN`
（或 PROD），且 test 部署还要求 `allowedAuthOrigins` 非空。

目前 `apps/desktop/.env.linux` 里用的是占位值 `https://example.invalid`。
它只影响打包产物里的 `dshMandatoryUpdatePolicy` 元数据，不影响构建能否完成，
但**发布前必须替换成真实决策**（真实 origin，或者为 Linux 明确关掉这条策略）。

---

## 补丁清单

全部相对上游 `477b4f4`，一个文件只属于一个补丁，按文件名顺序应用。
已验证：在 pristine worktree 上 7 个补丁按序 `git apply` 全部干净通过，且结果与开发工作树逐字节一致。

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0001-desktop-target-model-add-linux-x64.patch` | `desktop-build-paths.{mjs,d.mts}`、`desktop-auto-update-environment.{mjs,d.mts}` | target 白名单加 `linux-x64`；`desktopTargetPlatform` 返回 `'linux'`；新增 `desktopElectronExecutablePath()`（mac 在 bundle 里，win/linux 在根） |
| `0002-package-target-add-linux-x64.patch` | `package-target.ts`、`desktop-upload-plan.ts` | 打包目标表加 `linux-x64`（`--linux`/`--x64`）+ Linux 构建主机校验；放宽 `--unsigned` 到 win/linux |
| `0003-electron-builder-allow-unsigned-linux.patch` | `electron-builder-config.mjs` | 放宽 `unsigned builds require Windows` → Windows 或 Linux（AppImage 不需要签名） |
| `0004-prepare-target-electron-distribution.patch` | `prepare-runtime.ts`、`prepare-dsh.ts` | 修掉两处「非 mac 即 win32」/「用构建主机平台」的 Electron 路径推导，改用 target |
| `0005-desktop-linux-release-settings.patch` | `desktop-package-environment.{mjs,d.mts}`、`desktop-toolchain-preflight.ts`、`.gitignore`、`.env.linux.example` | 读 `.env.linux`；Linux 不套用 Windows/macOS 专属设置；工具链探测与类型联合接受 `linux` |
| `0006-desktop-package-linux-scripts.patch` | `apps/desktop/package.json` | 加 `package:linux:x64` / `package:linux:x64:dir`（都带 `--unsigned`） |
| `0007-tests-linux-x64-supported.patch` | 3 个 `tests/*.spec.ts` | 把「断言 Linux 抛错」改成「断言 Linux 受支持」，并补 `desktopElectronExecutablePath` 的用例 |

补丁 0007 单独跑过：`vitest run` 三个 spec 全绿（41 tests）。补丁应用后
`tsc -b tsconfig.host.json` 全绿（0 errors）。

### 仍未解决 / 待办

- **sharp 在 Electron 下的解码段错误**（本轮唯一硬阻塞，见上）。
- Linux 的 mandatory-update policy origin 需产品决策。
- `prepare-dsh.ts` 里 `const target = { platform: process.platform, … }` 用的是**构建主机**平台。
  在 Linux x64 主机上构建 linux-x64 恰好正确，但构建 linux-arm64 会错。本轮未改（保持最小补丁）。
- `desktopUpdateMetadataFilename` 仍拒绝 `linux`——目前只有 upload plan 与 macOS 打包用得到，
  Linux 走 unsigned（`update === undefined`）不经过它。若将来要 Linux 更新通道，需一并改。


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
