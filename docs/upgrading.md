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
2. 看上游这个基线把这几处改成了什么：`git -C upstream log --oneline -5 -- <这些文件>`
3. 手工把语义搬过去（不是照抄 hunk，要理解上游为什么改）
4. 重新生成这一个补丁：
   ```bash
   git -C upstream diff -- <该补丁涉及的文件> > patches/<同名文件>.patch
   ```
   注意：0001–0015 相对**干净基线**生成、0016–0018 叠加在其上，顺序不能动。
5. 同步改动：
   - `PKGBUILD` 里该补丁的 `sha256`；换了基线还要改 `_tag` / `_commit`（Arch 那条路用）
   - `patches/README.md` 里对应补丁的说明
6. `./scripts/upgrade.sh --check` 重跑到全绿

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
