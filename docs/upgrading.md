# 跟进官方新版本

上游迭代很快，而且明确写着会有破坏性变更。跟进分两条路，**先判断补丁能不能打上，再谈构建**——
因为 `patches/` 里每个 diff 都是相对 `PKGBUILD` 的 `_tag` 那个 commit 生成的。

## 一、先自检：新版本能不能打上补丁

```bash
cd ~/dsh-workspace/杂活/dsh-desktop-linux
./scripts/upgrade.sh --check              # 默认取上游最新的 dsh-v* tag
./scripts/upgrade.sh --check dsh-v0.2.2   # 也可以指定 ref
```

它会：撤销当前补丁 → 把 `upstream` 切到该 ref → 按文件名顺序**逐个真实应用**（0016–0018 叠加在
0001–0015 之上，只能按序真打，不能各自对着干净基线试打）→ 报告每个补丁 `OK / 3WAY / FAIL`。

- **全 OK**：树已停在「补丁已应用」状态，直接 `./scripts/build.sh --appimage` 就能构建。
- **有 FAIL**：脚本会**完整回滚**（`git reset --hard` + 清掉补丁新增文件），打印是哪个补丁、
  哪个文件打不上，以及重做步骤。回滚后工作树是干净的，不会留下半应用状态。

## 二、全自动那条路（推荐，省事）

把本仓库推到你的 GitHub，然后：

1. `.github/workflows/update-feed.yml` 每天扫一次上游 tag，发现新版本就自动
   `fetch-upstream → apply-patches → build --appimage → 发布到滚动的 linux-latest release`。
2. 产物里的 `DSH_DESKTOP_LINUX_UPDATE_ORIGIN` 指向该 release，所以**应用内「检查更新」会直接
   提示新版本**，用户点两下就升级（AppImage 替换自身）。
3. 补丁打不上时这条流水线会**失败并通知你**（GitHub 会发邮件），不会发出半成品。
4. 幂等键是「上游 ref + 补丁集指纹」，指纹记在 release 正文里（`patches/`、`PKGBUILD`、`assets/`、
   `scripts/` 与 workflow 自身的 git 树哈希）。所以**补丁修好之后推到 master 会立刻重发**，
   不必等定时任务、也不用去动上游 ref；只改 README 这类不在指纹里的文件则不会触发重编。
5. 重发时**版本号递增**：同一上游版本的第 1 次发布与上游一致，第 2 次起是
   `<上游版本>.<日期>.<序号>`（例如 `0.2.1-alpha.2.20261009.2`）。这一条是必需的——
   electron-updater 用 `semver.gt` 比较 feed 版本与已安装应用的 `app.getVersion()`，
   版本号不变就等于「已是最新」，老用户永远收不到这次补丁修复。序号记在 release 正文的
   `build-number` 里，每次发布 +1；格式由上游 `desktop-build-version.mjs` 校验，写错会在打包前报错。

前提是构建时 `apps/desktop/.env.linux` 里的地址指向你自己的源（workflow 会自动写）：

```dotenv
DSH_DESKTOP_LINUX_UPDATE_ORIGIN=https://github.com/JamesYasR/dsh-desktop-linux/releases/download/linux-latest
```

## 三、手动那条路（本机直接编）

```bash
./scripts/upgrade.sh                  # 全流程：切最新 tag + 打补丁 + 装依赖 + 构建 + 重装
./scripts/upgrade.sh --build v0.2.2   # 指定 ref
UPGRADE_SKIP_INSTALL=1 ./scripts/upgrade.sh   # 只构建，不重装
```

依赖 `pnpm 11`（上游 `packageManager: pnpm@11.7.0`）与 Node 24。首次构建较慢，之后
`.desktop-build/` 的缓存（Electron、Node/Python 运行时、已打包的 tgz）会复用。

构建完记得确认产物里嵌的是**你想要的更新源**：

```bash
grep -A3 '^provider' upstream/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked/resources/app-update.yml
```

## 四、补丁打不上时怎么重做

上游动到同一处代码就会冲突。脚本已经打印了步骤，这里是完整版：

1. 定位改动范围：`grep '^diff --git' patches/<失败的那个>.patch`
2. 看上游这个基线把这几处改成了什么——**先读上游 diff，再动手**：
   ```bash
   # 两个 tag 之间改了哪些文件、哪些行（比逐个试打快得多）
   git ls-remote --tags https://github.com/deepseek-ai/deepseek-harness.git 'dsh-v*'
   # 或者把两个版本的文件拉下来直接 diff
   ```
3. 手工把语义搬过去（不是照抄 hunk，要理解上游为什么改）。**要重做整个补丁时**，按
   `apply-patches.sh` 的思路建「基线 + 只有这一个补丁」的隔离树：`git apply --reject` → 看 `.rej`
   → 手改 → 取 diff，避免把别的补丁的 hunk 一起带进来。
4. 重新生成这一个补丁：
   ```bash
   git -C upstream diff -- <该补丁涉及的文件> > patches/<同名文件>.patch
   ```
   注意：0001–0015 相对**干净基线**生成，0016–0018 叠加在其上（0019 独立），顺序不能动。
5. 同步改动：
   - `PKGBUILD` 里该补丁的 `sha256`；换了基线还要改 `_tag` / `_commit`（Arch 那条路用）
   - `patches/README.md` 里对应补丁的说明
6. `./scripts/preflight.sh` 跑到全绿：它校验 PKGBUILD 的 `source`↔`sha256sums`（含源码包哈希）、
   两条路径打补丁并逐字节比对、以及 CI 会先跑到的 host 面类型检查——**先本地把 CI 会挂的事挂掉**。
7. `./scripts/upgrade.sh --check` 重跑到全绿

**两条只有踩过才知道的坑**（0.2.1-alpha.1 → alpha.2 那次踩齐了）：

- **「打得上」只说明上下文没变，不说明语义还对。** 上游把一段代码挪进/挪出某个函数时，补丁可能
  零冲突通过，但我们的假设已经失效：那次上游把 `runtime/bin/node` 的安装挪进了 `prepareCli()`，
  而我们在 Linux 上整段跳过它——补丁干净，产物里却少了包脚本要用的 `node`。凡是我们**整段跳过
  或整段替换**的函数，重做时必须逐行核对上游这次往里加了什么。
- **先跑一遍 `tsc` 再推。** 类型错误是流水线最前面的门，本地跑一次只要一分钟（`pnpm install`
  在有暖 store 时约 20 秒），比让它烧掉一整轮 CI（10 分钟以上）划算得多。

**重点盯这几个文件**（我们改动最重的地方，上游一动就冲突）：
`apps/desktop/scripts/electron-builder-config.mjs`、`desktop-package-environment.mjs`、
`package-target.ts`、`desktop-build-paths.mjs`、`src/main.ts`、`src/update-coordinator.ts`。

## 五、更新源怎么选

| 方式 | 适用 | 换源要重编吗 |
|---|---|---|
| `.env.linux` 里的 `DSH_DESKTOP_LINUX_UPDATE_ORIGIN` | 正式发布（GitHub Release 或任意静态 HTTPS） | 要 |
| 启动时同名环境变量 | 本地验证、临时换源、A/B 对比 | 不要（补丁 0017） |

feed 目录里只需要两个文件：`nightly-linux.yml`（通道元数据，通道名固定 `nightly`）和它引用的
AppImage。本地起一条源验证：

```bash
./scripts/serve-update-feed.sh          # 127.0.0.1:8899
APPIMAGE_PATH=/home/$USER/.local/opt/deepseek-harness/deepseek-harness.AppImage \
  ./scripts/verify-update.sh            # 断言应用真的查了这条 feed 并识别到更高版本
```

细节见 [updates.md](updates.md)。
