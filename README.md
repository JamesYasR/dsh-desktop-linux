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

## 阶段进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 建仓 + 隔离 | 完成 |
| 1 | dev 模式验证（窗口能否弹出） | 见 `docs/findings.md` |
| 2 | 定位打包失败点，打补丁 | 未开始 |
| 3 | 原生模块（node-pty / sharp） | 未开始 |
| 4 | 产物：AppImage → deb → rpm → PKGBUILD | 未开始 |
| 5 | 验证矩阵（协议、profile 隔离、端口） | 未开始 |
| 6 | 回到上游 Discussion 汇报 | 未开始 |

## 纪律

1. **`DSH_HOME` 必须指向临时目录。** 本机 3080 上跑着 GUI，`~/.dsh` 有 1.7G；
   桌面端要用 `profiles/desktop`，绝不能碰正在用的 `web` profile。
2. **磁盘**：`/home` 余量有限，构建吃 monorepo clone + pnpm store + Electron 二进制 + 产物。
3. **上游 Issues 与 PRs 都关闭**，只能 fork 或走 Discussion。
