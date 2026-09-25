# dsh-desktop-linux

给官方 DeepSeek Harness 桌面端补上 **Linux** 目标。

官方桌面端（`deepseek-ai/deepseek-harness` 的 `apps/desktop`）只发布 macOS 与 Windows，
Linux 被明确排除（`apps/desktop/README.md`: *"Linux is not a supported Desktop release target."*）。
本项目把官方 Electron 桌面端的**打包流水线**移植到 Linux，产物为 AppImage / deb / rpm / PKGBUILD。

这不是套壳。生态里已有的 Linux 桌面端几乎都是"启动 `dsh web` + 套个窗口"，
而官方桌面端有自己的 `dsh-app://` 协议、分帧字节管道、内置 Node 与 pnpm、独占 `desktop` profile，
只能从源码构建。

## 为什么是独立打包仓库

上游是超大 monorepo，fork 后 rebase 成本高。PKGBUILD 本来就是
"clone tag → 打补丁 → 构建"的形状，补丁文件也能直接拿去贴上游 Discussion。

```
dsh-desktop-linux/
├── README.md
├── docs/findings.md          ← 每次失败点记录，最值钱的产出
├── patches/                  ← 一个改动一个 patch（git format-patch）
├── scripts/
│   ├── fetch-upstream.sh     # clone + checkout 指定 tag
│   ├── apply-patches.sh
│   ├── build.sh
│   ├── dev-desktop.sh
│   └── verify.sh
├── PKGBUILD
└── .github/workflows/build.yml
```

## 用法

```bash
./scripts/fetch-upstream.sh              # 默认 master，可传 tag
./scripts/apply-patches.sh
./scripts/build.sh --dir                 # 先出未打包目录，快速验证
./scripts/verify.sh
```

dev 模式（阶段 1，已验证可起窗口）：

```bash
./scripts/dev-desktop.sh                 # 构建 + 起窗口
./scripts/dev-desktop.sh --no-devtools   # 不自动弹 DevTools
```

### 硬性前提

- **必须用 pnpm 11.x**（仓库要求 `packageManager: pnpm@11.7.0`）。系统 pnpm 9 会在
  `pnpm install` 报 `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`——`pnpm-workspace.yaml` 用了
  pnpm 10+ 的 `overrides` / `allowBuilds` / `minimumReleaseAgeExclude`。
- **`dev:desktop` 前必须先跑一次 `pnpm run build`**。`dev.ts` 的 import 是静态提升的，
  会在它自己那次构建之前解析 `lib/`，干净树上直接跑会 `ERR_MODULE_NOT_FOUND`。
- **dev 模式也需要 `patches/0001`**。`dev.ts` 虽然不碰 `package-target.ts`，但它调用
  `resolveDesktopBuildTarget()`，Linux 会抛 `unsupported target linux-x64`。

## 阶段进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 建仓 + 隔离 | 完成 |
| 1 | dev 模式验证（窗口能否弹出） | **完成：窗口正常弹出**，详见 `docs/findings.md` |
| 2 | 定位打包失败点，打补丁 | **完成：链路推进到 `prepare:dsh`**，卡在 sharp 段错误 |
| 3 | 原生模块（node-pty / sharp） | **完成：Linux 上 Host 改走 primary-runtime 的真 Node**，sharp 解码正常 |
| 4 | 产物：AppImage → deb → rpm → PKGBUILD | **进行中**：AppImage 已产出并实测能起窗口；deb / rpm / PKGBUILD 未做 |
| 5 | 验证矩阵（协议、profile 隔离、端口） | 部分提前验证：`dsh-app://` 正常、`profiles/desktop` 隔离、19387 端口一致 |
| 6 | 回到上游 Discussion 汇报 | 未开始 |

## 当前状态

打包流水线已经全程走通，产物能起来：

```
configuration ✓ → toolchain ✓ → build:official ✓ → release:pack ✓
→ prepare:runtime ✓ → prepare:packages ✓ → prepare:dsh ✓ → package ✓ → smoke:packaged ✓
```

`prepare:dsh` 的运行时冒烟里 `"sharp":true`——就是最初段错误的那一步。打包后的应用实测
能起窗口（标题 `DeepSeek Harness`，欢迎页正常），Host 进程的 executable 是
`resources/runtime/primary-runtime/dependencies/node/bin/node`。

关键结论：**Linux 上 Host 跑在 primary-runtime 自带的真 Node 上**，不再用 Electron 的 node 模式。
连带地，Linux 产物的 dsh 目录树不放进 asar（真 Node 读不了归档）。
细节与取舍见 `docs/findings.md` 的阶段 3 一节。

## 未决事项

- **deb / rpm 还没接**：需要 `linux.maintainer` 与 `homepage`（真实身份，只有维护者能给），
  rpm 还需要系统装 `rpmbuild`。PKGBUILD 也还没在干净 makepkg 环境里验证。
- **强制更新策略通道 Linux 不参与**：策略服务只认 `desktop-win` / `desktop-mac` 客户端身份，
  Linux 没有对应身份，而且 Linux 产物没有更新通道。所以 Linux 版不嵌入策略、不轮询，
  也不需要任何 `DSH_MANDATORY_UPDATE_*` 设置。若将来上游补上 Linux 身份，放开
  `desktopPlatformEmbedsPolicy()` 即可。

## 纪律

1. **`DSH_HOME` 必须指向临时目录。** 本机 3080 上跑着 GUI，`~/.dsh` 有 1.7G；
   桌面端要用 `profiles/desktop`，绝不能碰正在用的 `web` profile。
   注意：**DSH 会话自己会把 `DSH_HOME` 设成真实的 `~/.dsh`**，所以 `scripts/*.sh` 刻意
   不读 `DSH_HOME`，只读 `DSH_DESKTOP_LINUX_HOME`（默认 `/tmp/dsh-desktop-test`），
   并在 `DSH_HOME == $HOME/.dsh` 时直接退出。
2. **磁盘**：`/home` 余量有限，构建吃 monorepo clone + pnpm store + Electron 二进制 + 产物。
3. **上游 Issues 与 PRs 都关闭**，只能 fork 或走 Discussion。
