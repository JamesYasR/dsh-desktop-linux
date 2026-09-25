# 失败点与发现记录

每次失败/成功都往这里加一条。格式：日期、环境、命令、结果、结论。

---

## 2026-09-25 · 阶段 1 · dev 模式（go/no-go 关卡）

（待填：见下）

---

## 背景速查（来自 BRIEF.md，不必重查）

| 项 | 值 |
|---|---|
| 包名 | `@deepseek-ai/dsh-desktop`（`private: true`，不在 npm 上） |
| 版本 | 0.1.7-rc.2 |
| Linux 支持 | 明确不支持 |
| 目标类型 | `'mac-arm64' \| 'mac-x64' \| 'win-x64'` |
| `platform` 联合 | `'darwin' \| 'win32'` |
| Linux target 配置 | **已存在**：`linux: { category: 'Development', target: ['AppImage'] }` |
| URL scheme | `dsh://` |
| 默认端口 | 19387 |
| Linux 主机 | `hostTargetName()` → `linux-x64` → `isTargetName` 失败 → `unsupported build host linux-x64` |
| 未签名构建 | `unsigned && resolvedPlatform !== 'win32'` 直接抛错，AppImage 不需要签名，要放宽 |
