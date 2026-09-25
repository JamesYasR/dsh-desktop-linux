# 补丁

一个改动一个 patch，用 `git format-patch` 生成，便于 rebase 上游。

命名：`NNNN-短描述.patch`，按文件名顺序应用（见 `scripts/apply-patches.sh`）。

阶段 2 预计要动的三处：

1. `package-target.ts` 的三个类型联合 + `TARGETS` 表 + `hostTargetName()`
2. `electron-builder-config.mjs` 里 `unsigned && resolvedPlatform !== 'win32'` 那条限制
3. `apps/desktop/package.json` 加 `package:linux:x64` 脚本

目前为空——阶段 1（dev 模式）不走 `package-target.ts`，理论上不需要补丁。
