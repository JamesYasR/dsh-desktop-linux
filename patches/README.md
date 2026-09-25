# 补丁

一个改动一个 patch，按文件名顺序应用（见 `scripts/apply-patches.sh`）。

组织约定：**一个文件只属于一个补丁**。这样每个补丁都是相对同一个基线（上游 `477b4f4`）
的独立 diff，互不重叠，应用顺序无关但仍按编号执行。补丁由
`git diff -- <files>` 从开发工作树生成。

已验证：在 pristine worktree 上 7 个补丁按序 `git apply` 全部干净通过，结果与开发工作树逐字节一致。

| 补丁 | 覆盖文件 | 内容 |
|---|---|---|
| `0001-desktop-target-model-add-linux-x64.patch` | `desktop-build-paths.{mjs,d.mts}`、`desktop-auto-update-environment.{mjs,d.mts}` | target 白名单加 `linux-x64`；`desktopTargetPlatform` 返回 `'linux'`；新增 `desktopElectronExecutablePath()` |
| `0002-package-target-add-linux-x64.patch` | `package-target.ts`、`desktop-upload-plan.ts` | 打包目标表加 `linux-x64`；Linux 构建主机校验；放宽 `--unsigned` |
| `0003-electron-builder-allow-unsigned-linux.patch` | `electron-builder-config.mjs` | 允许 unsigned 的 Linux 构建（AppImage 不需要签名） |
| `0004-prepare-target-electron-distribution.patch` | `prepare-runtime.ts`、`prepare-dsh.ts` | Electron 分发路径按 target 推导，不再假设「非 mac 即 win32」 |
| `0005-desktop-linux-release-settings.patch` | `desktop-package-environment.{mjs,d.mts}`、`desktop-toolchain-preflight.ts`、`.gitignore`、`.env.linux.example` | 支持 `.env.linux`；Linux 不套用 Windows/macOS 专属设置 |
| `0006-desktop-package-linux-scripts.patch` | `apps/desktop/package.json` | `package:linux:x64` / `package:linux:x64:dir` |
| `0007-tests-linux-x64-supported.patch` | 3 个 `tests/*.spec.ts` | 把「断言 Linux 抛错」改成「断言 Linux 受支持」 |

## 注意

- **阶段 1（dev 模式）也需要 `0001`**——`dev.ts` 虽然不走 `package-target.ts`，
  但会调用 `resolveDesktopBuildTarget()`，Linux 上抛 `unsupported target linux-x64`。
- 上游有手写的 `.d.mts` 声明文件，改 `.mjs` 的 JSDoc **不够**，类型联合必须同步改 `.d.mts`，
  否则 `tsc` 报错。
- 补丁 0007 会让上游原本断言「Linux 不受支持」的三个 spec 改为断言受支持；
  单独跑 `vitest run` 41 tests 全绿。

详见 `docs/findings.md`。
