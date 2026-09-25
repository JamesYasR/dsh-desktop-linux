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

### 崩溃只发生在 Electron 的 **node 模式**，而 dsh 运行时正好跑在这个模式里

继续做变量分离，得到一个决定性的对照：

| 运行环境 | sharp 解码 | 备注 |
|---|---|---|
| 系统 Node v26.9.0 | ✅ | |
| Electron 44 **GUI 模式**（`electron <app>`） | ✅ `decode ok: 1 1 3` | 实测最小 GUI app |
| Electron 44 **node 模式**（`ELECTRON_RUN_AS_NODE=1`） | ❌ SIGSEGV | |
| primary-runtime 里的**真 Node 24.21.0** | ✅ | `dependencies/node/bin/node`，`process.versions.electron === undefined` |

也就是说：**GUI 主进程解码图像没问题，崩的是 Electron 的 Node 模式。**

坏消息是这个模式恰恰就是 dsh 运行时用的：

- `apps/desktop-host/src/index.ts:36` 在拉起 Host 时设 `ELECTRON_RUN_AS_NODE: '1'`
- 上游 `apps/desktop/README.md:64` 原文：
  > dsh runs under Electron with `ELECTRON_RUN_AS_NODE=1` and `--expose-internals`
- `scripts/node-bin/node` 本身就是个壳：`export ELECTRON_RUN_AS_NODE=1; exec "$DSH_DESKTOP_NODE_EXECUTABLE" --expose-internals "$@"`

所以 `sharp` 在桌面端的图像附件 / 图片卸载路径上会在 Linux 上把 Host 打崩。
**这不是测试假阳性**——冒烟测试（`tests/fixtures/runtime-payload-smoke.mjs`）正是为了
「在真正会跑的那个运行时下验证 payload」而存在的，它抓对了。

### 解法（已实施）：Linux 上让 Host 走 primary-runtime 的真 Node

见下面「阶段 3」一节。


---
---

## 2026-09-26 · 阶段 3 · 打通打包到可运行产物 —— **通过**

### 决策

采用候选方向 1：**Linux 上让 Host 跑在 primary-runtime 自带的真 Node 上**；
macOS / Windows 不变，继续用 Electron 的 node 模式。

证据链支持这个选择：真 Node 已经在产物里、已按 target 准备好，sharp 在它下面实测正常；
而 Electron 的 node 模式在 Linux 上必然把宿主机的 glib 链进自己的进程空间（electron#46323），
这不是靠白名单能绕开的。

### 实现：把「Host 运行时」变成一等概念（补丁 0008）

`apps/desktop/src/node-environment.ts` 是这条规则的唯一归属地：

```ts
export function desktopNodeRuntime(platform, electron, primaryRuntime): DesktopNodeRuntime {
  if (platform !== 'linux') return { executable: electron, electron: true }
  return { executable: join(primaryRuntime, 'dependencies', 'node', 'bin', 'node'), electron: false }
}
```

`electron` 字段不只是描述，它决定 `ELECTRON_RUN_AS_NODE` 要不要设。
这一步必须一起改：`pnpm` 内嵌的 `node-gyp-build` 系 `isElectron()` 读的就是这个变量，
真 Node 被标成 Electron 时它会去挑 electron ABI 的 prebuild。共三处：

- `desktopNodeEnvironment()`：只有 Electron 运行时才设 `ELECTRON_RUN_AS_NODE`；
  standalone 时设 `DSH_DESKTOP_NODE_ELECTRON=0`。
- `scripts/node-bin/node` 壳：`[ "${DSH_DESKTOP_NODE_ELECTRON:-1}" = 1 ]` 才 export。
  **默认值 1 是刻意的**——调用方清空环境时不会带上这个变量，缺省必须回落到 Electron 行为，
  否则 macOS / Windows 的包脚本会以 GUI 模式起 Electron。
- `apps/desktop-host/src/index.ts`：用 `process.versions.electron` 判断自己跑在哪个运行时下。

`RuntimeResources.node` 改名 `electron`（它本来就是 Electron 可执行文件），
Host 用哪个运行时由 `main.ts` 在构造 `DesktopHostProcess` 时解析并传入。

### 打包链路也必须用同一个运行时（补丁 0009）

`prepare:dsh` 里的 `pnpm install` 和 `runtime:smoke` 原先都拿 target 的 Electron 跑。
payload 的原生模块是按「谁来加载它」解析的，所以这两处也要用 Host 运行时，
否则会装出 electron ABI 的 prebuild、再拿真 Node 去 load。

`versions.json` 的 `node` 字段语义随之明确为「payload 实际运行的 Node 版本」：
Linux 记 primary-runtime 的 24.21.0，macOS / Windows 仍记 Electron 的 Node。
`tests/fixtures/runtime-payload-smoke.mjs` 里那两处 Electron 专属断言相应改成按平台判断。

### 产物布局：asar 与真 Node 不兼容（补丁 0003 / 0009）

`prepare:dsh` 通过后 electron-builder 能出 `linux-unpacked`，但**打包后的 smoke 立刻失败**：

```
Error: ENOTDIR: not a directory, open '…/resources/app.asar/dsh/desktop-runtime.json'
```

这不是测试的问题，是产品的问题：`host-process.ts` 用 `resources.dsh`
（= `app.getAppPath() + '/dsh'`）当 Host 的 runtimeDir，Electron 能透明读 asar，**真 Node 不能**。

所以 Linux 上不用 asar（`asar: resolvedPlatform !== 'linux'`）：
`resources/app/dsh` 就是一棵真目录树，`runtimeArchivePath()` 自然返回 undefined，
`installOfficeEngineResolution()` 的重定向也不再需要。
代价是丢掉 `verifyRuntimeArchive()` 的归档校验，改为在 `smoke-packaged-runtime.ts`
里对打包后的真目录树跑一次 `verifyDesktopRuntime()`。

顺带修掉一个 Linux 打包缺陷：electron-builder 默认拿 package name 当可执行文件名，
产出的是 `@deepseek-aidsh-desktop`。现在显式 `linux.executableName = 'deepseek-harness'`。

### mandatory-update 策略：Linux 不参与（补丁 0010，取代上一轮的「需要产品决策」）

上一轮记录的是「policy origin 必填，占位值发布前要换成真实值」。查到实情后结论变了。

**策略服务没有 Linux 客户端身份。** 身份由 `desktopClientHeaders()` 决定：

```ts
// packages/credentials/deepseek-account/src/index.ts:138
export function desktopClientHeaders(platform: 'darwin' | 'win32' | null) {
  if (platform === null) return {}
  return { 'x-client-platform': platform === 'win32' ? 'desktop-win' : 'desktop-mac' }
}
```

只有 `desktop-win` / `desktop-mac` 两种，`main.ts:1244` 也显式把策略限制在 win32 / darwin。
再加上 Linux 产物是 unsigned（`update === undefined`、`publish: null`），根本没有更新通道，
策略决定驱动不了任何动作。

所以 Linux 的正确行为是**不嵌入策略、不轮询**：新增 `desktopPlatformEmbedsPolicy(platform)`，
`validateDesktopPackageEnvironment()` 和 `createElectronBuilderConfig()` 都用它。
占位 origin 因此彻底消失——Linux 不再需要任何 `DSH_DESKTOP_MANDATORY_UPDATE_*` 设置。
将来若 upstream 给策略服务加上 Linux 身份，放开这个判定即可。

顺带修掉 `validateDesktopPackageEnvironment()` 里 `win32 ? … : macOS` 的隐含假设，
改成 win32 / darwin / 其余不适用。

### 一个必须记下来的操作陷阱：DSH_HOME

本机的 DSH 会话自己把 `DSH_HOME` 指向用户真实的 `~/.dsh`。
仓库脚本原先写的是 `${DSH_HOME:-/tmp/dsh-desktop-test}`，于是**继承了那个值**，
构建会往正在使用的数据目录里写东西。现在三个脚本都只读 `DSH_DESKTOP_LINUX_HOME`，
并在 `DSH_HOME == $HOME/.dsh` 时直接退出。

（本轮实测：`~/.dsh/profiles/` 下没有 `desktop`，也没有本轮时间窗内的写入。）

### 结果

```
configuration ✓ → toolchain ✓ → build:official ✓ → release:pack ✓
→ prepare:runtime ✓ → prepare:packages ✓ → prepare:dsh ✓ → package ✓ → smoke:packaged ✓
```

关键日志：

```
{"node":"24.21.0","platform":"linux","arch":"x64","koffi":true,"sharp":true,"html":true,"pty":true,"pnpm":true,"grep":true,"glob":true}
desktop runtime: DOCX, XLSX, PPTX to PDF and skill CLI discovery passed
  • executing @electron/fuses  electronPath=…/linux-unpacked/deepseek-harness
```

（同一个 payload smoke 跑了两遍：一遍对 `.desktop-build/…/dsh`，一遍对打包后的
`resources/app/dsh`。`"sharp":true` 就是最初那个段错误的位置。）

打包后的应用实测能起来：

```
$ DSH_HOME=/tmp/dsh-desktop-pkg ./deepseek-harness
LISTEN 127.0.0.1:19387  users:(("MainThread",pid=330076))
$ ps -eo cmd | grep dsh-desktop-host
…/resources/runtime/primary-runtime/dependencies/node/bin/node --expose-internals \
  …/resources/app/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js …
```

Host 进程的 executable 就是 primary-runtime 的真 Node，runtimeDir 是打包后的真目录树。
窗口截图确认：标题 `DeepSeek Harness`、菜单 `Application | Edit`、
正文 `Welcome to DeepSeek Harness` + `Sign in` / `Add API Key`。
产物里 `dshMandatoryUpdatePolicy` 字段已不存在。

### 桌面集成：窗口与 .desktop 的关联

electron-builder 会警告 `desktopName is not set in package.json`。Electron 从
`desktopName` 推导窗口 app_id，`StartupWMClass` 必须与之匹配，桌面环境才能把运行中的
窗口关联到这个 .desktop 条目。已设 `extraMetadata.desktopName = 'deepseek-harness'`
与 `linux.syncDesktopName: true`。

### 仍未解决 / 待办（阶段 3 结束时）

- ~~**deb / rpm 还没接**~~ → **阶段 4 已解决**。`linux.target` 原先只有 `AppImage`；
  electron-builder 的 deb/rpm 走 fpm，要求 `linux.maintainer` 与 `homepage` 两个包元数据
  （本仓库的 `package.json` 既没有 `author` 也没有 `homepage`，fpm 会直接报
  `authorEmailIsMissed` / `Please specify project homepage`）；rpm 还额外需要系统装
  `rpmbuild`（本机没有，Arch 上是 `rpm-tools`）。maintainer 是要写进 Debian control 的
  真实身份，属于需要产品输入的信息，所以当时没有先塞占位值。
- **AppImage 以 `--no-sandbox` 运行**。这是 electron-builder 对 AppImage 的默认行为
  （squashfs 挂载里的 `chrome-sandbox` 没法是 setuid root），生成的 .desktop 里
  `Exec=AppRun --no-sandbox %U`。也就是说 AppImage 版本没有 Chromium 沙箱——
  这正是 deb / rpm 有价值的地方（阶段 4 确认了它们的 `postinst` / `%post` 会按宿主机是否支持
  user namespace 决定 `chrome-sandbox` 是否 setuid，两种情况都有沙箱可用）。
  发 AppImage 前需要决定：接受无沙箱，还是改用 unprivileged user namespace 沙箱。
- **PKGBUILD 未在干净的 makepkg 环境里验证**。
- `desktopUpdateMetadataFilename` 仍拒绝 `linux`。Linux 走 unsigned 不经过它；
  将来要 Linux 更新通道才需要动。
- `linux-unpacked` 约 1.1G（asar 关闭后是小文件目录树）。AppImage 压成 squashfs 后 339M，
  但首次启动的文件读取比 asar 多。

## 2026-09-26 · 阶段 4 · 产物：AppImage / deb / rpm —— **通过**

### 先查清楚 fpm 到底要什么

deb / rpm 都由 electron-builder 的 fpm 目标产出，而 fpm 是 electron-builder **自己下载**的
（`~/.cache/electron-builder/fpm@2.1.4/fpm-1.17.0-ruby-3.4.3-linux-amd64.7z`），
**不需要系统装 ruby**。真正需要宿主机提供的东西只有一样：

| 格式 | 需要什么 |
|---|---|
| AppImage | 无（electron-builder 自带 appimage 工具） |
| deb | `ar` + `tar` + `xz`。**不需要 `dpkg`**——fpm 自己写 ar 归档 |
| rpm | `rpmbuild`（Arch 上是 `rpm-tools`），外加 `xz` |

`FpmTarget.computeFpmMetaInfoOptions()` 卡两个字段：

- `projectUrl = appInfo.computePackageUrl()`，为 null 就报 `Please specify project homepage`；
- `author = options.maintainer`，为 null 才回落到 package.json 的 `author.email`，没有就报
  `authorEmailIsMissed`。

`AppInfo.computePackageUrl()` 的取数链是 `metadata.homepage || devMetadata.homepage`，再回落到
GitHub 仓库地址。关键在 `packager.js`：

```js
this._originalMetadata = deepAssign({}, this._metadata)
deepAssign(this._metadata, configuration.extraMetadata)
```

`extraMetadata` 在 `AppInfo` 读取之前并进 `metadata`，所以 **homepage 能从 electron-builder
配置注入，不用动上游的 `package.json`**。maintainer 走 `linux.maintainer`，
homepage 走 `extraMetadata.homepage`。

### 决策：包元数据进 `.env.linux`，格式选择进环境变量

两者性质不同，所以去处也不同：

- **maintainer / homepage 是发布设置**——每个仓库一套，跟着 release 走。放
  `apps/desktop/.env.linux`，和 `DSH_DESKTOP_APP_ID` 同一层，由 `build.sh` 首次运行从
  `.env.linux.example` 生成。同时把 `DSH_DESKTOP_LINUX_.*` 加进
  `AMBIENT_RELEASE_SETTING`，保证它**只由文件拥有**（发布设置不从环境回落，这是原文件写死的规矩）。
- **打哪几种格式是构建选择器**——和 `DSH_DESKTOP_TARGET_PLATFORM` / `_ARCH` 同类，
  所以叫 `DSH_DESKTOP_TARGET_FORMATS`，只能从环境传，写进 `.env.linux` 会被白名单拒收。
  理由很实际：文件里的值会盖掉环境里的值，那样 `build.sh --deb` 就不管用了。

缺省只出 AppImage，所以 **AppImage-only 的构建不需要 maintainer/homepage**；只有选中 deb/rpm
才要求，而且校验发生在流水线最前面的 `configuration` 阶段，不会等 fpm 跑起来才报错。

### 三个「默认值其实是错的」的字段

第一版 deb 出来了，control 文件里有两处不对：

```
Section: default
Description: 
  Electron desktop shell for a bundled dsh runtime and external plugins
```

- `Section: default` 不是任何 Debian section（那是 fpm `--category` 的缺省值）。
- `Description` 第一行是空的。fpm 对 deb 拼的是 `` `${synopsis || ""}\n ${description}` ``，
  `linux.synopsis` 没设 → 第一行空。Debian policy 要求第一行是 synopsis。

rpm 那边更直接——**rpmbuild 直接失败**，而且 fpm 只把 exit code 抛出来，看不到原因：

```
{timestamp: "...", message: "Process failed: rpmbuild failed (exit code 1). ...", level: :error}
```

用 `FPM_DEBUG` 之外的办法复现（直接跑 fpm 加 `--debug`）才拿到真正那行：

```
error: line 39: Tag takes single token only: Name: DeepSeek Harness
```

根因：fpm 的包名来自 `appInfo.linuxPackageName`。package.json 的 name 是
`@deepseek-ai/dsh-desktop`（scoped），于是回落到 `sanitizedProductName` = `DeepSeek Harness`
——**带空格**。deb 后端会静默把它改写成 `deepseek-harness`（所以 deb 一直是对的，
但那是巧合），rpm 后端原样写进 spec，`Name:` 就带了空格。

顺带确认了一件事：**安装路径里的空格不是问题**。`/opt/DeepSeek Harness` 是
`LinuxTargetHelper.installPrefix`（常量 `/opt`）+ `sanitizedProductName`，fpm 的 rpm 后端能正确
处理——单独跑一个最小 fpm 复现验证过 `rpm -qpl` 列出的路径是对的。所以只需要钉住包名。

最终显式给出 `deb.packageName` / `rpm.packageName` / `deb.packageCategory` /
`rpm.packageCategory` / `linux.synopsis`。

### 产物元数据（实测）

```
$ rpm -qip deepseek-harness-0.1.7-rc.2-linux-x86_64-unsigned.rpm
Name        : deepseek-harness
Version     : 0.1.7~rc.2
Release     : 1
Architecture: x86_64
Group       : Development/Tools
Size        : 1123373413
License     : MIT
Packager    : ffyfox <299493445+ffyfox@users.noreply.github.com>
Vendor      : ffyfox <299493445+ffyfox@users.noreply.github.com>
URL         : https://github.com/deepseek-ai/deepseek-harness
Summary     : DeepSeek Harness desktop application
```

```
$ ar x …deb && tar xOf control.tar.xz ./control
Package: deepseek-harness
Version: 0.1.7~rc.2
Architecture: amd64
Maintainer: ffyfox <299493445+ffyfox@users.noreply.github.com>
Installed-Size: 1097044
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libuuid1, libsecret-1-0
Recommends: libappindicator3-1
Section: devel
Priority: optional
Homepage: https://github.com/deepseek-ai/deepseek-harness
Description: DeepSeek Harness desktop application
  Electron desktop shell for a bundled dsh runtime and external plugins
```

两点值得记：

- **`0.1.7-rc.2` 变成 `0.1.7~rc.2`**。fpm 把预发布的 `-` 换成 `~`，这是对的：
  Debian 的版本序里 `~` 排在空串之前，所以 `0.1.7~rc.2 < 0.1.7`。rpm 也吃 `~`
  （`rpmlib(TildeInVersions)`）。不需要我们干预。
- **rpm 的依赖保留了 rich dependency**：`(libXtst or libXtst6)`、`(libuuid or libuuid1)`
  原样进了 header，这是 electron-builder 给 rpm 的缺省 depends 里的写法。

### deb 的 postinst 顺手把「沙箱」这件事回答了

阶段 3 留了个疑问：AppImage 的 `.desktop` 带 `--no-sandbox`（squashfs 里的 `chrome-sandbox`
没法是 setuid），deb 是不是就能有沙箱。答案在 electron-builder 生成的 `postinst` 里：

```bash
if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; }; then
    # Use SUID chrome-sandbox only on systems without user namespaces:
    chmod 4755 '/opt/DeepSeek Harness/chrome-sandbox' || true
else
    chmod 0755 '/opt/DeepSeek Harness/chrome-sandbox' || true
fi
```

也就是说 **deb 是有沙箱的**，走哪条路由宿主机决定：内核支持 unprivileged user namespace 就用
namespace 沙箱（不打 setuid），不支持才退回 setuid `chrome-sandbox`。rpm 的 `%post` 是同一份脚本。
`postinst` 还会用 update-alternatives 注册 `/usr/bin/deepseek-harness`，并在检测到 AppArmor
支持时装一份随包分发的 profile（`resources/apparmor-profile` 确实在包里）。

### 结果

```
configuration ✓ → toolchain ✓ → build:official ✓ → release:pack ✓
→ prepare:runtime ✓ → prepare:packages ✓ → prepare:dsh ✓ → package ✓ → smoke:packaged ✓
```

一次 `--all` 跑出三个产物，`smoke:packaged` 照常通过（`"sharp":true`）：

| 产物 | 大小 |
|---|---|
| `…-linux-x86_64-unsigned.AppImage` | 339M |
| `…-linux-amd64-unsigned.deb` | 291M |
| `…-linux-x86_64-unsigned.rpm` | 233M |

`./scripts/verify.sh`：10 通过 / 0 失败。

## 补丁清单

见 `patches/README.md`——那里是补丁清单的唯一归属地（本文件不再重复一份，之前那份已经和
实际文件名对不上了）。

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
