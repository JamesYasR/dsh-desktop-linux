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
- ~~**AppImage 以 `--no-sandbox` 运行**~~ → **阶段 4 已解决**。这是 electron-builder 对 AppImage
  的默认行为（squashfs 挂载里的 `chrome-sandbox` 没法是 setuid root），生成的 .desktop 里
  `Exec=AppRun --no-sandbox %U`。也就是说 AppImage 版本没有 Chromium 沙箱——
  当时以为 deb / rpm 才有沙箱（阶段 4 确认了它们的 `postinst` / `%post` 会按宿主机是否支持
  user namespace 决定 `chrome-sandbox` 是否 setuid）。实际上 AppImage 也能有：
  去掉那个写死的 flag、交给 AppRun 的探测即可，见下面阶段 4 一节。
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

### AppImage 的 `--no-sandbox`：不用接受，一行配置就能拿回沙箱

第一版 AppImage 里解出来的 `.desktop` 是：

```
Exec=AppRun --no-sandbox %U
```

也就是**从桌面菜单启动的每一次都没有 Chromium 沙箱**。当时我把它记成「发 AppImage 前需要决定接不接受」，
但把来源和实测都做了一遍之后，这个说法站不住。

**这个 flag 是 electron-builder legacy 工具集的缺省值**（`AppImageTarget.js:26`）：

```js
const appimageTool = packager.config.toolsets?.appimage
const defaultArgs = appimageTool == null || appimageTool === "0.0.0" ? ["--no-sandbox"] : []
```

只有 `0.0.0`（当前缺省）加；`1.0.2` / `1.0.3` 那两个静态 runtime 工具集不加（文档里都标着 Beta）。

**而 AppRun 自己已经有正确的判断**：

```bash
if [ $HAVE_NO_SANDBOX -eq 0 ] && ! unshare -Ur true 2>/dev/null ; then
  NO_SANDBOX=(--no-sandbox)
fi
```

探测到 user namespace 不可用才自己补。所以 AppRun 是好的，**写死 flag 的 `.desktop` 才是问题**。

实测（只取该 AppImage 自己的渲染进程，看 user namespace inode 与 seccomp 状态）：

| 启动方式 | 渲染进程 user-ns | seccomp |
|---|---|---|
| 不带 flag | `4026532736`（独立 namespace） | 2（过滤器生效） |
| 带 `--no-sandbox` | `4026531837`（与主进程同一个） | 0（无） |

所以「AppImage 没法沙箱」不成立：squashfs 挂载是 `nosuid` 只说明 **setuid helper** 用不了，
而 Chromium 还有 **unprivileged user namespace** 这条路。

**解法**：给 AppImage 目标显式一个空参数表。

```js
appImage: { executableArgs: [] },
```

`[]` 不是 nullish，`this.options.executableArgs ?? defaultArgs` 不会回落到 `defaultArgs`，
`Exec` 就变成 `AppRun %U`，决定权回到 AppRun 的探测。

必须写在 `appImage:` 这一层而不是 `linux.executableArgs`：target 的 options 是按名字合的
（`AppImageTarget` 用 `config.appImage`，`FpmTarget` 用 `config.deb` / `config.rpm`），
而 `[]` 在 JS 里是 truthy，`linux.executableArgs: []` 会让 deb/rpm 的 `Exec` 走进
`if (executableArgs)` 分支、多出一个空格（`"…" %U` 变 `"…"  %U`）。写在 `appImage` 层就只影响 AppImage。

实测三个产物的 `Exec`：

```
AppImage: Exec=AppRun %U
deb:      Exec="/opt/DeepSeek Harness/deepseek-harness" %U
rpm:      Exec="/opt/DeepSeek Harness/deepseek-harness" %U
```

重打后的 AppImage 按新的 `.desktop` 方式启动，渲染进程仍在独立 user namespace 且 seccomp 生效。

副作用（正面）：修之前菜单启动无沙箱、终端直接跑有沙箱，同一个产物两种行为；现在一致了。
仍然无沙箱的场景只剩「宿主机不支持 user namespace」——那时 AppRun 会自己补 flag，
这是环境所限，不是我们主动关掉的。

### PKGBUILD：Arch 包（以及为什么不用 electron-builder 自带的 pacman target）

electron-builder 有 `target: 'pacman'`，但它的默认依赖表是 Electron 2 时代的
（`FpmTarget.js` 的 `getDefaultDepends('pacman')`）：`c-ares` `ffmpeg` `gtk3` `http-parser`
`libevent` `libvpx` `libxslt` `libxss` `minizip` `nss` `re2` `snappy` `libnotify`
`libappindicator-gtk3`。`http-parser` / `re2` / `snappy` 早就不在 Electron 的依赖里；
`libappindicator-gtk3` 在 Arch 官方仓库里也已经没有了（现在叫 `libayatana-appindicator`），
而且实测打包后的 `deepseek-harness` 里根本没有 appindicator 相关的字符串，只有
`StatusNotifierItem` / `StatusNotifierWatcher`（Chromium 自带的 DBus 实现）——这个包不需要它。
所以手写 PKGBUILD。

**源码用 release 源码包，不用 `git+`。** 两个选项都实测过：

| | release tarball | `git+…#tag=` |
|---|---|---|
| 下载体积 | 32MB | 242MB（makepkg 做 `git clone --mirror`，实测 36 秒） |
| 校验 | sha256 固定 | makepkg 用 `git archive` 算，tag 本身不可变 |
| 额外补丁 | 需要 0012 | 不需要 |

代价是 release 源码包里没有 `.git`，而上游有两条路都要 git：
`scripts/build.ts` 经 `repositoryCommitHash()` 读 `HEAD`——它有 `DSH_CLIENT_COMMIT_HASH`
出口，不用改；`package-target.ts:364` 无条件调 `readDesktopBuildCommit()`——没有出口，
所以要补丁 0012。PKGBUILD 显式给三个变量：

```
DSH_CLIENT_COMMIT_HASH=$_commit
DSH_DESKTOP_BUILD_COMMIT=$_commit
DSH_DESKTOP_BUILD_DIRTY=1
```

`_DIRTY=1` 不是将就：这个构建确实打了 12 个补丁，`dshBuildDirty` 记 `true` 是事实。
顺带验证了没有 `.git` 时其余环节是安全的：`lefthook` 的 postinstall 和
`scripts/install-lefthook.mjs` 都在 `git rev-parse` 失败时直接返回。

**补丁必须平铺在 PKGBUILD 旁边。** makepkg 的 `get_filepath()` 用 `get_filename()`
（basename）在 `$startdir` 里找本地 source，实测：

```
source=('sub/deep.patch')
==> ERROR: deep.patch was not found in the build directory and is not a URL.
```

所以 `source=('patches/0001-….patch')` 是不行的。`scripts/aur-dir.sh` 把 PKGBUILD、
`.install` 和 12 个补丁摊平到一个目录（默认 `./aur`，已 gitignore），那里面就是可以直接提交
AUR 的内容；仓库里保留 `patches/` 只是为了让补丁系列本身可读。

**`prepare()` 必须能从失败中重跑。** makepkg 只在成功时清 `$srcdir`
（`clean_up()` 里 `EXIT_CODE == E_OK && BUILDPKG && CLEANUP`）。失败重跑时它会重新解包源码包，
把补丁改过的文件恢复原状，**却留下补丁新增的文件**（0005 的 `.env.linux.example`）——于是 0005
变成「一半已应用」，`patch -N` 正反向都打不上。中间试过干跑探测，还踩了一个坑：
`patch --batch --dry-run` 遇到「新增文件已存在」会自动 `Assume -R` 并返回 0，于是真的去应用、
然后失败（`-N` 才是既抑制询问又给对退出码的写法）。最终改成在 `prepare()` 里直接从源码包重建
工作树；代价是重跑会丢掉 `.desktop-build` 里的 Electron 下载缓存（~120MB）。

**安装布局用 `/opt/deepseek-harness-desktop`（无空格），不是上游 deb/rpm 的
`/opt/DeepSeek Harness`。** `.desktop`、图标名、`StartupWMClass`、可执行文件名都照上游
（`deepseek-harness`）；只有 AppArmor profile 里的路径要改。

这里踩到一个实测出来的坑：**`resources/apparmor-profile` 是 fpm 的 deb/rpm target 写进
linux-unpacked 的**（`FpmTarget` 里 `copyFile(scripts.appArmor, resourceDir/apparmor-profile)`），
只出 `--dir` 的构建没有这个文件。第一版 `package()` 去 sed 它，直接
`sed: can't read …/resources/apparmor-profile: No such file or directory`——整条构建跑了十分钟，
倒在最后一步。现在 profile 内容直接写在 PKGBUILD 里。图标没有这个问题：
`resources/icon.png` 是 `--dir` 构建自带的（1024×1024）。

**依赖是算出来的，不是抄的。** 起点是上游 deb control 里那 9 个（`libgtk-3-0` `libnotify4`
`libnss3` `libxss1` `libxtst6` `xdg-utils` `libatspi2.0-0` `libuuid1` `libsecret-1-0`），
换成 Arch 包名，再加上 ldd 显示、而 Debian 那边由传递依赖带来的 `alsa-lib` / `dbus`
（libuuid 在 Arch 属于 `util-linux`，在 base 里，不列）。验证方法：`ldd` 主二进制拿到 93 个
soname，对已声明 `depends` 的传递闭包（177 个官方仓库包）求覆盖——**全覆盖**。

`namcap PKGBUILD`：**0 error**，只剩两类 warning——「dependency X detected and implicitly
satisfied」（传递依赖，正常），以及「`libnotify` / `libxss` / `libxtst` / `xdg-utils` / `libsecret`
可能不需要」。这五个正是上游自己声明的运行时依赖，通过 dlopen / exec 使用，namcap 看不到。
（这里说的只是 PKGBUILD 层级；包层级是另一套规则，见本节末「namcap 的两个层级」。）

**pnpm 版本不用管。** 仓库声明 `packageManager: pnpm@11.7.0`，Arch 的 `pnpm`（11.26）会自己
切过去——实测在仓库里 `pnpm --version` 输出 `11.7.0`。所以 `makedepends=('pnpm')` 就够，
PKGBUILD 只校验主版本号 ≥ 11。`makedepends` 里的 `python` 是 node-gyp 的后备：实测这次构建
一个原生模块都没编（node-pty / sharp / koffi / native-system 全部命中预编译产物）。

**构建需要网络**：源码包、npm 包、Electron 二进制，以及 `prepare:runtime` 下载的
primary-runtime（Node + pnpm + Python）。本机访问 github 需要代理，那是本机环境，与 PKGBUILD
无关——第一次跑就是因为我把它从环境里剥掉，才在 `prepare:runtime` 撞上
`ConnectTimeoutError: github.com:443`。

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

Arch 包（PKGBUILD）：

```
sources+sha256 ✓ → prepare() 12 个补丁 ✓ → pnpm install ✓ → build:official ✓
→ release:pack ✓ → prepare:runtime ✓ → prepare:packages ✓ → prepare:dsh ✓
→ electron-builder --dir ✓ → smoke:packaged ✓ → package() ✓
```

| 产物 | 大小 |
|---|---|
| `deepseek-harness-desktop-0.1.7rc2-1-x86_64.pkg.tar.zst` | 351M（安装后 1071MiB，24902 个文件） |

`namcap PKGBUILD`：0 error（包级别是另一套规则，见本节末「namcap 的两个层级」）。`pacman -U`
装上后实测：`/usr/bin/deepseek-harness` →
`/opt/deepseek-harness-desktop/deepseek-harness`，窗口正常起（Welcome 页），19387 端口监听，
Host 进程是 `resources/runtime/primary-runtime/dependencies/node/bin/node`（即 primary-runtime
自带的真 Node，和阶段 3 的结论一致），渲染进程在独立 user namespace（`4026533617`）且 seccomp
生效，`chrome-sandbox` 保持 0755——内核支持非特权 user namespace 时按上游 postinst 的判断不装
SUID。`post_upgrade` 也实测过：先把 `chrome-sandbox` 改成 4755，重装一次，脚本片段又把它改回
0755。`pacman -R` 卸载无残留。

干净环境验证：从 `archlinux-bootstrap` 起了一个只有 base + base-devel + makedepends 的 chroot
（`nodejs` `pnpm` `python`，运行库只装 PKGBUILD 里 `depends` 声明的那几个），在里面跑
`makepkg`。走通的部分：源码包下载 + sha256、12 个补丁、`pnpm install --frozen-lockfile`
（**冷 store，`.npmrc` 里只有 registry，没有 `allow-scripts`**——也就是说构建脚本白名单确实由
仓库的 `pnpm-workspace.yaml` 提供，不依赖开发机配置）、`build:official`、`release:pack`、
`prepare:runtime`、`prepare:packages`，以及 `prepare:dsh` 里那次打包期 `pnpm install`。
最后倒在 `prepare:dsh` 把 node_modules 拷进 app 目录那一步：宿主 btrfs 已经写满
（`Device unallocated: 1 MiB`，`df` 报的 17G 是 chunk 内的剩余，btrfs 分配不出新 metadata chunk），
报 `ENOSPC`。这是磁盘限制不是 PKGBUILD 问题——剩下的 `electron-builder --dir` 和 `package()`
在宿主上跑通了（`package()` 里那个 apparmor 坑就是第一次宿主跑出来的）。

### namcap 的两个层级（一个我写错过的结论）

`namcap PKGBUILD` 和 `namcap <包文件>` 是两套不同的规则集，结论完全相反。README 里原先写的
「`namcap` 0 error」只对前者成立；包级别实测是 **25 条 error tag + 4758 条 warning tag**。
原话没写清层级，等于说错了，这里更正。

| namcap 包级别报告 | 条数 | 为什么不是 PKGBUILD 的缺陷 |
|---|---|---|
| `Referenced python module … is an uninstalled dependency` | 4445 W | 包里带着完整的 python 运行时，namcap 把 site-packages 里 import 的每个模块都当成缺系统依赖 |
| `ELF file … lacks FULL RELRO` / `is unstripped` / `lacks PIE` | 111 / 52 / 13 W | 上游预编译的 `.node` / `.so`；`options=('!strip')` 也是刻意的 |
| `Unused shared library …` | 101 W | 同上 |
| `Dependency … detected and not included`（python-* / pyside6 / nodejs / libxcrypt-compat） | 19 E | 同第一行 |
| `Insecure RPATH/RUNPATH` | 6 E | 上游预编译二进制；有一条 RUNPATH 直接写着 `…/work/sherpa-onnx/…/build/install/lib`——GitHub runner 的构建目录漏进了二进制 |
| `ELF files outside of a valid path ('opt/')` | 1 E | namcap 自己把 `opt/` 列进 `questionable_dirs`（`Namcap/rules/elffiles.py`），而 Arch 允许自包含应用装 `/opt` |

所以 CI 里 `namcap PKGBUILD` 当门禁（必须 0 error），`namcap <包文件>` 只报告。

**顺带一个 namcap 假阳性**：`namcap PKGBUILD` 一开始报 `File referenced in $startdir`，来源是
PKGBUILD 头部注释里那个变量名的**字面量**——`invalidstartdir` 规则
（`Namcap/rules/invalidstartdir.py`）扫的是整份文件包括注释，看到 `$` 加 `startdir` 就当成真的
引用。实测确认：把注释里的字面量换成「PKGBUILD 所在目录」，这条 E 立刻消失（0 E / 2 W）。
PKGBUILD 里现在留了一行注释说明，免得以后有人「顺手」把变量名写回去。剩下那 2 条 warning 是
`uses internal makepkg 'msg2' / 'error' subroutine`，属于风格提示，没改。

## 2026-09-26 · 阶段 5 · 验证矩阵 —— **通过**

BRIEF 阶段 5 列了五项。这一轮把它们从「看着像对」变成可复现的检查，写进了
`scripts/verify.sh`：静态部分（19 项）不启动应用、CI 能跑；加 `--runtime` 会额外拉起
`linux-unpacked`，用 DevTools 协议读渲染文档，跑完自动收掉。本机实测
`./scripts/verify.sh --runtime`：**29 通过 / 0 失败 / 0 跳过**。

| BRIEF 阶段 5 的检查 | 结果 | 证据 |
|---|---|---|
| 窗口起得来 | ✓ | 标题 `DeepSeek Harness`、菜单 `Application \| Edit`、欢迎页 `Sign in` / `Add API Key` |
| `dsh-app://` 协议加载 UI 正常 | ✓ | CDP 目标 `dsh-app://app/`，节点数稳定在 445，正文含 `New Session` / `Plugins` / `Workspaces` |
| 与 CLI **共享** `~/.dsh`（会话 / 设置 / 凭据） | ✓ | 同一根下：会话 `<根>/sessions/<工作区>/session-*.v4.jsonl.zstd`、凭据 `<根>/.credentials.yaml`、身份 `<根>/.anonymous-user-id`——都在**根上**，不在任何 profile 里 |
| **独占** `profiles/desktop`，不污染 `web` profile | ✓ | CLI 拒绝 `--profile desktop`（exit 1）；CLI 在同一根上跑完 `--profile web --dump-config` 后，`profiles/desktop` 四个文件逐字节未变；`profiles/web` 的哨兵未被动过 |
| 不跟 3080 上的服务打架 | ✓ | 19387 与 3080 是两个进程（08:01 / 07:06 启动），都只监听 `127.0.0.1`，3080 全程可用 |

### 「UI 真的加载了」怎么测，而不是「进程还在」

`ss` 只说明有东西在监听；`dsh-app://` 是 Electron 自定义协议，**目标存在也不等于文档有内容**
（空白文档同样是个目标）。所以用 `--remote-debugging-port` 连 DevTools 协议，直接对文档求值：

```
$ curl -s --noproxy '*' http://127.0.0.1:9222/json/list      # → page | DeepSeek Harness | dsh-app://app/
```

`Runtime.evaluate` 读到的是：

| 目标 | href | 节点数 | 正文开头 |
|---|---|---|---|
| 欢迎窗 | `file://…/resources/app/renderer/welcome.html` | 49 | `Welcome to DeepSeek Harness … Sign in Add API Key` |
| 主窗 | `dsh-app://app/` | 445 | `New Session Ctrl N Plugins Workspaces Default workspace …` |

**一个时序坑**：19387 开始监听时 renderer 还在加载，此时取样会拿到 152 个节点这样的中间态。
`verify.sh` 里等的是「连续两次取样节点数相同」再取值，稳定后是 445。最初我只等
`>100`，于是脚本报的是 152——数字虽然过了阈值，但它不是稳定态。

### 共享根与 profile 独占：交叉测过

两边都调 `resolveDshHome()`（`$DSH_HOME` → `~/.dsh`），桌面端把它拼成
`<根>/profiles/desktop`（`apps/desktop/src/paths.ts:19`）。实测而不是只读代码：

- 给桌面端 `DSH_HOME=/tmp/…`，它把 `profiles/desktop`、`sessions/`、`storages/`、
  `.credentials.yaml`、`.anonymous-user-id` **全部建在那个根下**；
- 再把**打包产物自带的 CLI** 指向同一个根跑 `--profile web --dump-config`（输出 1246 行组合树，
  exit 0），`profiles/desktop` 的四个文件 sha256 逐一不变；
- 两个 profile 的脚手架结构完全一样：`cordis.yml` + `cordis.patch.yml` + `package.json` +
  `pnpm-workspace.yaml`。

**独占是上游设计，不是我们的约定**：`apps/cli/src/args.ts:83` 的 `rejectElectronProfile()`
对 `profile.toLowerCase() === 'desktop'` 直接报错，所以 `dsh --profile Desktop` 也一样被拒——
CLI 和 Electron 不可能写同一个 profile。`--runtime` 里也顺带断言了真实的 `~/.dsh` 没有出现
`profiles/desktop`。

### `dsh://` URL scheme：三种产物一致，但注册链路要 `update-desktop-database`

`electron-builder-config.mjs` 里声明了 `protocols: [{ schemes: ['dsh'] }]`，产物里的
`.desktop` 都带 `MimeType=x-scheme-handler/dsh;`：

| 产物 | Exec | MimeType | StartupWMClass |
|---|---|---|---|
| AppImage | `AppRun %U` | ✓ | `deepseek-harness` |
| deb | `"/opt/DeepSeek Harness/deepseek-harness" %U` | ✓ | `deepseek-harness` |
| PKGBUILD | `"/opt/deepseek-harness-desktop/deepseek-harness" %U` | ✓ | `deepseek-harness` |

PKGBUILD 那份是照抄 deb 里 electron-builder 生成的那份，只换前缀——逐字比对过，包括
`StartupWMClass`（Electron 从 `desktopName` 推导窗口 app_id，两者必须一致）。

`MimeType` 只让这个条目**候选**，要进 `mimeinfo.cache` 才会被桌面环境看见，而那是
`update-desktop-database` 的活。上游 deb 的 postinst **显式调用**它；我们的 `.install` 没有。
**但这里不需要改**：Arch 的 `desktop-file-utils` 提供 pacman hook
（`/usr/share/libalpm/hooks/update-desktop-database.hook`，`PostTransaction` 触发），
而 `desktop-file-utils` 被 `gtk3` `gtk4` `mpv` `steam` 依赖——桌面系统上必然存在。
在 `.install` 里再调一次既冗余也违反 Arch 的打包惯例。

**我差点记下一条错的结论。** 在隔离的 `XDG_DATA_DIRS` 里测注册时，`gio mime
x-scheme-handler/dsh` 报「没有默认应用」，我一度以为 `.desktop` 有问题。做了变量隔离才看清：

| 变量 | Exec | GLib 是否认出 |
|---|---|---|
| a | `"/opt/deepseek-harness-desktop/deepseek-harness" %U`（包没装，路径不存在） | ✗ |
| b | `/bin/true %U` | ✓ |
| c | `/nonexistent/path %U` | ✗ |

**GLib 会隐藏 Exec 目标不存在的桌面项**。把同一份 `.desktop` 的 Exec 换成真实存在的二进制后，
`gio mime x-scheme-handler/dsh` 立刻报 `Default application … deepseek-harness.desktop`。
所以那个「没注册」纯粹是「包没装」的假象，不是缺陷。对照组用的是同目录、同 cache 的
`x-scheme-handler/zzztest`。

### 新发现：Linux 上客户端对 Platform 自称 macOS

查 `dsh://` 时顺带撞见的。`packages/credentials/deepseek-account/src/index.ts:138`：

```js
export function desktopClientHeaders(platform) {
  if (platform === null) return {}
  return { 'x-client-platform': platform === 'win32' ? 'desktop-win' : 'desktop-mac' }
}
```

用**打包产物里的 built lib** 实测：`win32 → desktop-win`、`darwin → desktop-mac`、
**`linux → desktop-mac`**、`null → web`。而 Linux 上确实会走到这里：

- `apps/desktop/src/main.ts:409` 是 `process.platform === 'win32' ? 'win32' : 'darwin'`——
  Linux 上显式传 `'darwin'`（内嵌 Platform 视图这条路径）；
- `apps/desktop/src/main.ts:1247` 是 `process.platform as 'win32' | 'darwin'`（类型断言，
  运行时是 `'linux'`）。但它被上一行 `if (!['win32','darwin'].includes(process.platform)) throw`
  挡住，而这条只在 `policyConfig !== undefined` 时才可达——Linux 产物 manifest 里没有
  `dshMandatoryUpdatePolicy`（补丁 0010），所以**这条在 Linux 上不可达**，与「Linux 不嵌入策略」一致。

同一份 `auth_exchange` 请求里还有个自相矛盾：`x-client-platform: desktop-mac`，而
`device_model` 来自 `node:os` 的 `platform()`，在 Linux 上是 `linux-x64`
（`deepseek-account-platform/src/index.ts:572`）。

这不是我们引入的缺陷，**是上游的类型联合 `'darwin' | 'win32' | null` 在 Linux 上被迫二选一的结果**。
README 原先写「Linux 没有对应身份」不准确——准确说法是：**Linux 客户端报的是
`desktop-mac`，一个假身份**。`verify.sh` 把这三个映射当回归断言钉住了。要不要动它属于上游决策
（真要支持 Linux，正确做法是给联合类型加 `'linux'` 并让服务端认识 `desktop-linux`），本项目不动。

### 沙箱与运行时（复测）

- Host 进程的 executable 是 `resources/runtime/primary-runtime/dependencies/node/bin/node`；
- 2 个渲染进程各自在独立 PID namespace（与主进程不同）且 `Seccomp: 2`，主进程 `Seccomp: 0`；
- `chrome-sandbox` 保持 `0755`（内核支持非特权 user namespace，按上游 postinst 的判断不装 SUID）；
- 19387 与 9222 都只绑 `127.0.0.1`。

### 这一轮**没有**验证到的

- 三种产物**装到系统后**的 `dsh://` 端到端行为（点一个 `dsh://` 链接真的拉起窗口）——
  上面验的是 `.desktop` 内容与注册链路，没装机实测。
- 「桌面端建的会话被 CLI 读回来」这种双向读写。验到的是：两端解析到同一个根、
  共享根里确实有桌面端写下的会话/凭据/身份文件、且互不覆盖对方的 profile。
- deb / rpm 装到系统后的行为（阶段 4 只对 Arch 包做过 `pacman -U` 实测）。
- CI 的两个 job 仍然没有端到端跑过（本地没有 runner）。

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
